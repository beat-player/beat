-- The screen around a page: the sidebar, the top bar, the player bar, the scan cards and the
-- toasts, with the page in the middle and the open overlays over all of it. A full-screen overlay
-- is the whole screen instead. Views are functions of state and window; they return elements and
-- messages, and never change the app themselves.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local metrics = require("beat.app.metrics")
local surfaces = require("beat.app.surfaces")
local sidebar = require("beat.app.chrome.sidebar")
local topbar = require("beat.app.chrome.topbar")
local playerBar = require("beat.app.chrome.player_bar")
local mobileNav = require("beat.app.chrome.mobile_nav")
local scanStatus = require("beat.app.chrome.scan_status")
local toasts = require("beat.app.chrome.toasts")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local shell = {}

-- A page slide has the same handful of positions every time. They are made once per scale and
-- picked from, rather than made from the frame's exact progress: a style is interned by its
-- values, so asking for one per frame is asking the arena to grow with every transition.
---@type table<number, { forward: wonderland.StyleBuilder[], back: wonderland.StyleBuilder[] }>
local transitionCache = {}
local TRANSITION_STEPS = 16

---@param theme beat.ui.Theme
---@return { forward: wonderland.StyleBuilder[], back: wonderland.StyleBuilder[] }
local function transitionStyles(theme)
	local cached = transitionCache[theme.scale]
	if cached ~= nil then return cached end

	local forward, back = {}, {}
	for at = 0, TRANSITION_STEPS do
			local t = at / TRANSITION_STEPS
			local distance = (1 - t) * theme:px(28)
			local dim = 0.88 + 0.12 * t
			forward[at] = sty():fill():column():offset(distance, 0):bright(dim)
			back[at] = sty():fill():column():offset(-distance, 0):bright(dim)
		end

	cached = { forward = forward, back = back}
	transitionCache[theme.scale] = cached
	return cached
end

--- The open overlays from `from` up, bottom first. An anchored overlay is drawn by the screen
--- that opened it, at the button that opened it, and a full-screen one is the screen itself.
---@param app beat.App
---@param window wonderland.RenderWindow
---@param from number
---@return wonderland.Element[]
local function overlays(app, window, from)
	local elements = {}
	for at = from, #app.overlays do
			local overlay = app.overlays[at]
			local surface = surfaces.overlay(overlay.name)
			if not surface.anchored and not surface.fullscreen and surface.view ~= nil then
				local element = surface.view(app, overlay, window)
				if element ~= nil then elements[#elements + 1] = element end
			end
		end
	return elements
end

---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element
function shell.view(app, window)
	local theme = app.services.appearance.theme
	local assets = app.assets
	if assets ~= nil then app.services.covers:use(assets) end
	app.services.covers:beginFrame()

	local width = window.width
	local height = window.height
	local mobile = metrics.mobile(app, width)
	local bar = app.services.playback:current() ~= nil and theme:px(mobile and 64 or 88) or 0
	local page = app:currentPage()

	-- A full-screen overlay is the screen, not a panel over one: the page, the sidebar and the bar
	-- are not built at all, so nothing underneath can be clicked through and nothing around the
	-- edges is left showing. What was opened over it is drawn over it.
	for at = #app.overlays, 1, -1 do
			local overlay = app.overlays[at]
			local surface = surfaces.overlay(overlay.name)
			if surface.fullscreen and surface.view ~= nil then
				-- The screen itself may be padded, but overlays are placed in window coordinates. A
				-- bare wrapper keeps their fill and offsets measured from the window.
				local frame = div():style(sty():fill()):children({ surface.view(app, overlay, window)})
				for _, element in ipairs(overlays(app, window, at + 1)) do frame:children({ element}) end
				app.services.covers:sweep()
				return frame
			end
		end

	if app.services.scan:needsFolder() then
		-- The first launch is the folder browser and nothing else; it is the page, too, so its
		-- messages reach it.
		if page.kind ~= "folders" then
			app.page = app:pageFor({ kind = "folders"})
			page = app.page
		end
		return div()
		:style(sty():fill():column():bg(theme:color("bg")):fg(theme:color("text"))
		:font(theme.fontFamily))
		:children({
		div():style(sty():fill():column():align("center"):justify("center")):children({
		div():style(sty():w(math.min(theme:px(620), width - metrics.pad(app, width) * 2))
		:h(theme:px(600)):column():gap(theme:space(18))):children({
		div():style(sty():row():h(theme:px(28)):gap(theme:px(10)):align("center")):children({
		ui.icons.element("logo", theme:px(28), theme:color("accent")),
		text("beat"):style(theme:s():text(theme:type("xxl")):weight("bold")
		:fg(theme:color("text"))),
		}),
		surfaces.page("folders").view(app, page, window),
		}),
		}),
		})
	end

	local content = surfaces.page(page.kind).view(app, page, window)

	local bottomHeight = metrics.bottomHeight(app, width)
	local pageHeight = height - bottomHeight
	local topbarHeight = metrics.topbarHeight(app, width)
	local bodyHeight = pageHeight - topbarHeight
	local scroll = app.services.scroll:offset(app:pageKey())

	local motion = app.services.motion
	local transitionStyle
	local t = motion:slideProgress(wonderland.time.now())
	if t ~= nil and not motion.clock.reduce then
		local transitionSet = transitionStyles(theme)
		local direction = (motion.pageSlide.direction or 1) < 0 and transitionSet.back or transitionSet.forward
		transitionStyle = direction[math.floor(t * 16 + 0.5)]
	end

	local pageBody = div()
	:style(sty():column():wrel(1.0):h(bodyHeight):pad(theme:space(20), metrics.pad(app, width), 0,
	metrics.pad(app, width)):gap(theme:space(18)):bar(theme:px(8), theme:px(40), theme:color("faint")))
	:scroll(scroll)
	:onScroll(function(by, to) return { type = "scroll", key = app:pageKey(), by = by, to = to} end)
	:children({ content})

	-- The page is moved by a wrapper whose styles are made once per scale, not by a style that
	-- names the frame's exact position: a style is interned by its values, and interning a new
	-- one every frame is what made repeated transitions slower and slower.
	local moving = transitionStyle == nil and pageBody
	or div():style(transitionStyle):children({ pageBody})

	-- Clipped so a page arriving from the side cannot draw over the sidebar during its travel.
	local pageClip = div():style(sty():column():wrel(1.0):h(bodyHeight)):scroll(0)
	:onScroll(function(by, to) return { type = "scroll", key = app:pageKey(), by = by, to = to} end)
	:children({ moving})

	local rightWidth = width - metrics.sidebarWidth(app, width)
	local main = div():style(sty():column():w(rightWidth):h(pageHeight))
	if not mobile then
		main:onMouseMove(function()
			if app.services.sidebar.hover ~= nil then return { type = "hoverPlaylist", id = nil} end
			return nil
		end)
	end
	main:children({
	topbar.view(app, width),
	div():style(sty():column():wrel(1.0):h(bodyHeight)):children({ pageClip}),
	})

	local shellChildren = { main}
	if not mobile then table.insert(shellChildren, 1, sidebar.view(app, width, pageHeight)) end
	local frame = div():style(sty():row():wrel(1.0):h(pageHeight)):children(shellChildren)

	local rootChildren = { frame}
	if mobile then
		if bar > 0 then rootChildren[#rootChildren + 1] = playerBar.mobile(app, width) end
		rootChildren[#rootChildren + 1] = mobileNav.view(app, width)
	elseif bar > 0 then
		rootChildren[#rootChildren + 1] = playerBar.view(app, width)
	end
	local scanIsland = scanStatus.island(app, width)
	if scanIsland ~= nil then rootChildren[#rootChildren + 1] = scanIsland end
	local scanSummary = scanStatus.summary(app, width)
	if scanSummary ~= nil then rootChildren[#rootChildren + 1] = scanSummary end
	if not mobile then
		local tooltip = sidebar.tooltip(app, width, height)
		if tooltip ~= nil then rootChildren[#rootChildren + 1] = tooltip end
	end

	local root = div()
	:style(sty():fill():column():bg(theme:color("bg")):fg(theme:color("text"))
	:font(theme.fontFamily))
	:children(rootChildren)

	local toastLayer = toasts.view(app, window)
	if toastLayer ~= nil then root:children(toastLayer) end

	for _, overlay in ipairs(overlays(app, window, 1)) do root:children({ overlay}) end

	-- Everything this view asked for is kept; covers a changing page no longer asks for are
	-- given back before the next frame, so a scan cannot accumulate one texture per album.
	app.services.covers:sweep()

	return root
end

return shell
