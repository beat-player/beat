-- The performance overlay's numbers: how many frames wonderland drew in the last second, how much
-- main-thread CPU a frame took from its first measure to the gpu being handed it, and how much
-- memory the process holds. The service watches what is already being drawn rather than asking for
-- frames of its own: the line is rebuilt only while frames are coming, and a screen that has gone
-- quiet is redrawn once to say so and then left alone.
local wonderland = require("wonderland")
local cache = require("beat-ui.cache")
local metrics = require("beat.app.components.helpers.metrics")
local stats = require("beat.app.services.debug.stats")
local fs = require("fs")

local time = wonderland.time
local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

-- The span the rate and the frame times are about: the last second, as a person reading an fps
-- counter means it.
local SPAN = 1
-- A frame count is worth a new line four times a second at most: a number that changes with every
-- frame is a string built for every frame of the app it is measuring.
local FORMAT_INTERVAL = 0.25
-- A second without a frame is a screen that is idle rather than one running slowly. The overlay
-- says so once, which is the one frame the overlay asks for itself.
local IDLE = 1
-- A frame asked for by the idle refresh is not one of the app's: it is matched by when it was
-- asked for, because a frame has no room to carry a flag through the event loop.
local SELF_FRAME = 0.5
-- /proc is read at most twice a second; the resident size of a process does not change faster
-- than that in a way the overlay is asked about.
local RSS_INTERVAL = 0.5
-- An fps of 512 is already far past any display beat draws on, and the ring is what lets a frame
-- be recorded without building a list of frames.
local CAPACITY = 512
local PAGE_KIB = 4096 / 1024

-- `/proc/self/statm` is the one process size Linux and Android both keep: resident pages, which
-- a page size turns into the memory the process actually holds. Neither Windows nor macOS has
-- it, so there the line has no resident size rather than a number made from another source.
local HAS_RSS = jit ~= nil and jit.os == "Linux"

-- What a frame costs is the main thread's own CPU time, not time on a wall clock: a frame waits
-- for a swapchain image and for the display to take the last one, and that wait is the display's
-- pace rather than work. Linux and Android keep a clock per thread that does not run while the
-- thread sleeps; elsewhere the wall clock is what there is.
local ffi = require("ffi")
local threadClock = nil
if HAS_RSS then
	-- Declared under a name of its own, so a `clock_gettime` another module declared with its own
	-- timespec type cannot clash with this one.
	ffi.cdef([[
		struct beat_timespec { long tv_sec; long tv_nsec; };
		int beat_clock_gettime(int clock, struct beat_timespec *ts) __asm__("clock_gettime");
	]])
	local CLOCK_THREAD_CPUTIME_ID = 3
	local spec = ffi.new("struct beat_timespec")
	threadClock = function()
		ffi.C.beat_clock_gettime(CLOCK_THREAD_CPUTIME_ID, spec)
		return tonumber(spec.tv_sec) + tonumber(spec.tv_nsec) * 1e-9
	end
end
local cpuNow = threadClock or time.now

local function readRssKiB()
	if not HAS_RSS then return nil end
	local statm = fs.read("/proc/self/statm")
	if statm == nil then return nil end
	local resident = statm:match("^%d+%s+(%d+)")
	if resident == nil then return nil end
	return tonumber(resident) * PAGE_KIB
end

---@class beat.DebugService: beat.Service
---@field app beat.App
---@field samples beat.Debug.Window
---@field lastFrameAt number?
---@field viewedAt number?
---@field idleShown boolean
---@field selfRefreshAt number?
---@field frameStart number?
---@field cachedLine string?
---@field cachedAt number?
---@field rssKiB number?
---@field rssAt number?
---@field uiPlugin wonderland.plugin.UI?
---@field renderPlugin wonderland.plugin.Render?
---@field originalFrame fun(...)?
---@field wrappedFrame fun(...)?
---@field originalDraw fun(...)?
---@field wrappedDraw fun(...)?
local Debug = {}
Debug.__index = Debug
Debug.needs = { "app" }

---@param deps { app: beat.App }
---@return beat.DebugService
function Debug.new(deps)
	return setmetatable({
		app = deps.app,
		samples = stats.Window.new(SPAN, CAPACITY),
		idleShown = false
	}, Debug)
end

--- Frames are counted where they are actually drawn: the ui's frame is timed from its start,
--- and the renderer's draw is the moment the frame has been handed over. Both are wrapped once
--- per plugin rather than looked up per frame, and a restart gives the app new plugin tables for
--- `close` to have handed the originals back to.
function Debug:resolve()
	local app = self.app
	local ui = app.uiPlugin
	if ui ~= nil and ui.frame ~= self.wrappedFrame then
		local frame = ui.frame
		local debug = self
		local wrapped

		self.uiPlugin = ui
		self.originalFrame = frame
		---@param this wonderland.plugin.UI
		---@param window wonderland.RenderWindow
		wrapped = function(this, window)
			debug.frameStart = cpuNow()
			frame(this, window)
			debug.frameStart = nil
		end
		self.wrappedFrame = wrapped
		ui.frame = wrapped
	end

	local render = app.renderPlugin
	if render ~= nil and render.draw ~= self.wrappedDraw then
		local draw = render.draw
		local debug = self
		local wrapped

		self.renderPlugin = render
		self.originalDraw = draw
		---@param this wonderland.plugin.Render
		---@param ctx wonderland.plugin.Render.Context
		wrapped = function(this, ctx)
			local drawn = draw(this, ctx)
			if drawn then debug:presented(ctx) end
			return drawn
		end
		self.wrappedDraw = wrapped
		render.draw = wrapped
	end
end

--- One frame the gpu was handed. A frame the overlay asked for itself while the app was idle is
--- what says the app has gone quiet, so it is not counted as the app drawing.
---@param _ctx wonderland.plugin.Render.Context
function Debug:presented(_ctx)
	local now = time.now()
	if self.selfRefreshAt ~= nil then
		local own = now - self.selfRefreshAt <= SELF_FRAME
		self.selfRefreshAt = nil
		if own then return end
	end

	local started = self.frameStart
	local duration = started ~= nil and (cpuNow() - started) * 1000 or 0
	self.samples:record(now, duration)
	self.lastFrameAt = now
	self.idleShown = false
end

---@param now number
function Debug:step(now)
	self:resolve()

	-- A refresh whose frame never came -- a minimized window has no target to draw into -- is
	-- forgotten rather than left to swallow the next frame the app does draw.
	if self.selfRefreshAt ~= nil and now - self.selfRefreshAt > SELF_FRAME then self.selfRefreshAt = nil end

	local last = self.lastFrameAt
	if last == nil then return nil end

	if now - last >= IDLE then
		-- The screen has been still for a second: one frame says idle, and then the overlay waits
		-- for the app to draw again rather than asking for a frame every second.
		if self.idleShown then return nil end
		self.idleShown = true
		self.selfRefreshAt = now
		return true
	end

	-- Frames are coming anyway. A view that has not been built for a second is one whose numbers
	-- are stale -- an animation drawn by a canvas rebuilds no view -- so one rebuild is asked for
	-- at most a second, which is a rebuild the frame already coming pays for.
	if self.viewedAt == nil or now - self.viewedAt >= IDLE then return true end
	return nil
end

---@param now number
---@return number?
function Debug:rss(now)
	if not HAS_RSS then return nil end
	if self.rssAt ~= nil and now - self.rssAt < RSS_INTERVAL then return self.rssKiB end
	self.rssKiB = readRssKiB()
	self.rssAt = now
	return self.rssKiB
end

--- The line the overlay draws, rebuilt at most four times a second: a view built for a pointer
--- move does not also build the numbers again when they are the ones it already has.
---@param now number
---@return string
function Debug:line(now)
	local cached = self.cachedLine
	if cached ~= nil and self.cachedAt ~= nil and now - self.cachedAt < FORMAT_INTERVAL then
		return cached
	end
	local line = stats.format(self.samples:summary(now), collectgarbage("count"), self:rss(now))
	self.cachedLine = line
	self.cachedAt = now
	return line
end

---@param ctx beat.ui.Context
---@param x number
---@param y number
local function overlayStyles(ctx, x, y)
	local pad = ctx:space(6)
	return {
		-- The layer is the whole window and paints nothing: only the chip is seen, and a pointer
		-- over the rest of it reaches the page under it as it did before.
		layer = sty():fill():offset(0, 0):z(85),
		-- A box with no size of its own fills what holds it, so the chip is given the room its two
		-- monospace lines take: 252 by 48 at the theme's scale, which leaves the longest line a
		-- few characters of room. The width is fixed so the box does not resize as digits come and
		-- go, which is what would make the numbers under it move.
		chip = sty()
			:column()
			:offset(x, y)
			:w(ctx:px(252))
			:h(ctx:px(48))
			:pad(pad, pad, pad, pad)
			:radius(ctx:radius("sm"))
			:bg(ctx:color("elevated", 0.9))
			:border(math.max(1, ctx:px(1)), ctx:color("border")),
		-- Monospace so a rate of 59 and one of 60 do not move every other number on the line.
		text = sty():font("monospace"):text(ctx:type("xs")):fg(ctx:color("text", 0.92))
	}
end

--- The overlay as the shell draws it, under the status bar's inset the same way the pages are.
---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element
function Debug.overlay(app, window)
	local service = app.services.debug
	-- A window's first frame can be built before the first tick has run, so the hooks are put in
	-- place here as well: the frame this view is part of is not timed, but every one after it is.
	service:resolve()
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local now = time.now()
	local top = metrics.insets()
	local x, y = theme:space(8), top + theme:space(8)
	---@type { layer: wonderland.StyleBuilder, chip: wonderland.StyleBuilder, text: wonderland.StyleBuilder }
	local styles = cache.of(ctx, overlayStyles, "debugOverlay", x, y) --[[@as { layer: wonderland.StyleBuilder, chip: wonderland.StyleBuilder, text: wonderland.StyleBuilder }]]

	service.viewedAt = now

	return div():style(styles.layer):children({
		div():style(styles.chip):children({
			text(service:line(now)):style(styles.text)
		})
	})
end

--- The app is being built again: the plugin tables it is about to replace get their own frames
--- and draws back, so a second service does not measure through the first one's closure.
function Debug:close()
	if self.uiPlugin ~= nil and self.uiPlugin.frame == self.wrappedFrame then
		self.uiPlugin.frame = self.originalFrame
	end
	if self.renderPlugin ~= nil and self.renderPlugin.draw == self.wrappedDraw then
		self.renderPlugin.draw = self.originalDraw
	end
	self.uiPlugin, self.wrappedFrame = nil, nil
	self.renderPlugin, self.wrappedDraw = nil, nil
	self.frameStart, self.selfRefreshAt = nil, nil
end

return Debug
