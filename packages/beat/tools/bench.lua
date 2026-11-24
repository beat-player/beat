-- A repeatable run of the app's hot paths, headless, against a copy of the real config directory:
-- startup, the first frame of every page, steady redraws, a library scroll, search typing, a page
-- slide and the now-playing overlay. Each scenario prints milliseconds per frame (split into the
-- app's own view and wonderland's layout and draw) and the Lua heap it leaves behind.
--
--   lde run tools/bench.lua                 # timings
--   lde run --memprof tools/bench.lua       # with allocation sites and labelled heap snapshots
--   lde run --profile tools/bench.lua       # with the hottest functions
--
-- BEAT_BENCH_CONFIG names the config directory to copy (default: the real one).
--
-- BEAT_BENCH_MODE runs one scenario only, at a phone's geometry unless told otherwise, and prints
-- the bytes each frame allocates (`collectgarbage("count")` with the collector stopped) and the
-- frame time's mean, p95 and worst:
--
--   BEAT_BENCH_MODE=scroll BEAT_BENCH_PAGE=home lde run tools/bench.lua
--   BEAT_BENCH_MODE=idle|scroll|playing   what the frames do: a page standing still, the page
--                                         scrolled by 40 px a frame, or a track playing
--   BEAT_BENCH_PAGE=home|library|library-list|album|artist|playlists|search|settings
--   BEAT_BENCH_WIDTH / HEIGHT / DENSITY   window geometry (default a Pixel 7: 1080×2400 at 2.625)
--   BEAT_BENCH_FRAMES=240                 how many measured frames
--   BEAT_BENCH_STEP=40                    pixels the `scroll` mode moves per frame
--   BEAT_BENCH_COVERS=1                   also step the cover service every eighth frame, as the
--                                         ticker does; off by default so the numbers are the
--                                         frame's own allocations rather than image decoding
--   BEAT_BENCH_WL=<dir>                    run against a wonderland tree at <dir>/wonderland
--                                         instead of the published copy under target, for
--                                         measuring a fix before it is synced
local wonderlandRoot = os.getenv("BEAT_BENCH_WL")
if wonderlandRoot ~= nil then
	package.path = wonderlandRoot .. "/?.lua;" .. wonderlandRoot .. "/?/init.lua;" .. package.path
end
local fs = require("fs")
local path = require("path")
local wonderland = require("wonderland")
local paths = require("beat.paths")

local memprof = package.loaded["lde.memprof"] --[[@as { snapshot: fun(label: string) }?]]
local wonderlandElement = require("wonderland.element")
local wonderlandStyle = require("wonderland.style")
local now = wonderland.time.now

local source = os.getenv("BEAT_BENCH_CONFIG") or paths.directory()
local config = os.tmpname() .. "-beat-bench"
os.remove(config)
fs.mkdirAll(config)
for _, name in ipairs({ "library.json", "settings.json", "tags.json", "session.json" }) do
	local bytes = fs.read(path.join(source, name))
	if bytes ~= nil then fs.write(path.join(config, name), bytes) end
end
paths.directory = function() return config end

-- The bench draws the cached library and never walks the music folder: a cache an older scan wrote
-- is taken as current, and a scan that would start anyway is refused.
--
-- The version is the one field that changes, so the copy is bumped as text rather than read into
-- Lua tables and written back: the document is two megabytes, and decoding it compiled several
-- megabytes of traces and left tables the benchmark then measured as the app's own heap. The
-- function keeps the strings out of this chunk's locals so the read copy can be collected.
---@param file string
local function bumpCacheVersion(file)
	local bytes = assert(fs.read(file), "the bench needs a library cache in " .. source)
	assert(bytes:find('"version":%s*%d+') ~= nil, "the benchmark cache has no version")
	local bumped = bytes:gsub('"version":%s*%d+', '"version":7', 1)
	fs.write(file, bumped)
end
bumpCacheVersion(path.join(config, "library.json"))
require("beat.app.services.scan.job").start = function() error("the bench does not scan") end

local mode = os.getenv("BEAT_BENCH_MODE")
local phone = mode ~= nil
local benchWidth = tonumber(os.getenv("BEAT_BENCH_WIDTH") or "") or (phone and 1080 or 1440)
local benchHeight = tonumber(os.getenv("BEAT_BENCH_HEIGHT") or "") or (phone and 2400 or 900)

-- The phone's geometry: its display density makes a length in the theme's units 2.625 physical
-- pixels, and the system bars cover a strip of the window top and bottom. A desktop run keeps the
-- neutral screen `beat.platform` reports.
if phone then
	local density = tonumber(os.getenv("BEAT_BENCH_DENSITY") or "") or 2.625
	local inset = math.floor(24 * density + 0.5)
	require("beat.platform").screen = function() return { density = density, top = inset, bottom = inset } end
end

local results = {}

local function heapKiB()
	collectgarbage()
	collectgarbage()
	return collectgarbage("count")
end

local function snapshot(label)
	if memprof then memprof.snapshot(label) end
end

local viewTime = 0
-- What the view function alone allocated, when `BEAT_BENCH_SPLIT=1`: the frame's tables and
-- styles, without the layout solve and the draw a window also does.
local viewKiB = 0
local splitView = os.getenv("BEAT_BENCH_SPLIT") == "1"

---@param label string
---@param frames number
---@param before fun(frame: number)?
---@param draw fun()
local function scenario(label, frames, before, draw)
	viewTime = 0
	local started = now()
	for frame = 1, frames do
		if before then before(frame) end
		draw()
	end
	local total = (now() - started) * 1000
	results[#results + 1] = {
		label = label,
		frames = frames,
		perFrame = total / frames,
		viewPerFrame = viewTime * 1000 / frames,
		heap = heapKiB()
	}
	snapshot(label)
end

local baseline = heapKiB()
snapshot("start")

local startedAt = now()
local App = require("beat.app")
local requiredAt = now()
App:init({})
local initAt = now()
local heapAfterInit = heapKiB()
snapshot("init")

local screenAt = now()
local screen
screen = wonderland.headless.new(function(window, assets)
	local at = now()
	App.window = window
	App.assets = assets
	App.services.covers:use(assets)
	local before = splitView and collectgarbage("count") or 0
	local element = require("beat.app.shell").view(App, window)
	if splitView then viewKiB = viewKiB + (collectgarbage("count") - before) end
	viewTime = viewTime + (now() - at)
	return element
end, { width = benchWidth, height = benchHeight })
local screenMs = (now() - screenAt) * 1000
App.layoutPlugin = screen.plugins.layout
App.uiPlugin = screen.plugins.ui
App.window = screen.window

local ui = screen.plugins.ui

-- A frame as the window loop makes one after an event: the screen is owed a frame, and the frame
-- is built, solved, walked and drawn.
local function draw()
	ui:requestRedraw(screen.window, true)
	screen.window.shouldRedraw = false
	ui:frame(screen.window)
end

local firstAt = now()
draw()
local firstFrame = (now() - firstAt) * 1000

-- Lets the cover service decode what the page asked for, as the ticker would between frames.
local function settleCovers()
	for _ = 1, 200 do
		local _, busy = App.services.covers:step(now())
		if not busy then break end
	end
	draw()
end

local library = App.services.library.current
assert(library ~= nil, "the bench needs a library cache in " .. source)

-- A stand-in for the audio player: a playhead that moves with the frame, and whatever the scenario
-- writes into the spectrum's levels. Both the full suite and a focused `playing` run drive one.
---@param album beat.Album
---@return { at: number }
local function installPlayer(album)
	local Queue = require("beat.app.services.playback.queue")
	local state = { at = 30 }
	local player = App.services.playback.player
	player.queue = Queue.new(album.tracks, 1, {})
	player.loaded = true
	player.startAt = nil
	player.player = setmetatable({
		position = function() return state.at end,
		duration = function() return 240 end,
		isPlaying = function() return true end,
		isFinished = function() return false end,
		update = function() end,
		close = function() end,
		setVolume = function() end,
		setEqualizer = function() end
	}, { __index = function() return function() end end }) --[[@as treble.Player]]
	local current = assert(player:current())
	App.services.playback.lastListenedTrackId = current.id
	return state
end

if mode then
	local pageName = os.getenv("BEAT_BENCH_PAGE") or "home"
	local routes = {
		home = { kind = "home" },
		library = { kind = "library" },
		["library-list"] = { kind = "library" },
		album = { kind = "album", id = library.albums[1].id },
		artist = { kind = "artist", id = library.artists[1].id },
		playlists = { kind = "playlists" },
		search = { kind = "search" },
		settings = { kind = "settings" }
	}
	local route = assert(routes[pageName], "unknown BEAT_BENCH_PAGE " .. pageName) --[[@as beat.Route]]
	local frames = tonumber(os.getenv("BEAT_BENCH_FRAMES") or "") or 240
	local stepCovers = os.getenv("BEAT_BENCH_COVERS") == "1"
	local scrollStep = tonumber(os.getenv("BEAT_BENCH_STEP") or "") or 40

	App.services.settings.values.view = pageName == "library-list" and "list" or "grid"
	App.page = App:pageFor(route)
	draw()
	if pageName == "search" then App:act({ type = "search", value = "the night" }) end
	settleCovers()
	App.services.scroll.offsets[App:pageKey()] = 0
	draw()

	local function percentiles(times)
		local count = #times
		local total = 0
		for at = 1, count do total = total + times[at] end
		local ordered = {}
		for at = 1, count do ordered[at] = times[at] end
		table.sort(ordered)
		return total / count, ordered[math.max(1, math.ceil(count * 0.95))], ordered[count]
	end

	--- The allocations of `frame` over `count` frames, with the collector stopped so every byte
	--- stays counted: the difference in `collectgarbage("count")` is what the frames made.
	---@param label string
	---@param count number
	---@param before (fun(at: number): any)?
	---@param frame fun(at: number): any
	local function run(label, count, before, frame)
		viewKiB = 0
		local times = {}
		for at = 1, count do times[at] = 0 end
		collectgarbage()
		collectgarbage("stop")
		local startKiB = collectgarbage("count")
		for at = 1, count do
			if before ~= nil then before(at) end
			local began = now()
			frame(at)
			times[at] = (now() - began) * 1000
		end
		local allocated = collectgarbage("count") - startKiB
		collectgarbage("restart")
		collectgarbage()
		local mean, p95, worst = percentiles(times)
		print(string.format(
			"%-28s %5d frames  %7.2f KiB/frame  mean %6.2f ms  p95 %6.2f ms  worst %6.2f ms",
			label,
			count,
			allocated / count,
			mean,
			p95,
			worst
		))
		if splitView then print(string.format("%-28s view only %7.2f KiB/frame", "", viewKiB / count)) end
		-- How big the tree a frame builds is, and how many distinct styles have been interned: a
		-- frame that interns a new style each time is a frame building a style from a value.
		print(string.format("%-28s %d elements, %d styles interned", "", wonderlandElement.count(), wonderlandStyle.count()))
	end

	local window = screen.window

	-- Warm the frame before measuring it: the first runs of a font, a style and a cover are made
	-- once and kept, and a steady-state measurement must not charge them to every frame. The cover
	-- decodes finish on their workers while these frames are drawn.
	local function warm(count)
		for _ = 1, count do
			App:tick(now(), window)
			draw()
		end
		settleCovers()
	end

	warm(120)

	if mode == "scroll" then
		local key = App:pageKey()
		run("scroll " .. pageName, frames, function(at)
			App.services.scroll.offsets[key] = at * scrollStep
			if stepCovers and at % 8 == 0 then App.services.covers:step(now()) end
		end, draw)
	elseif mode == "redraw" then
		run("redraw " .. pageName, frames, nil, draw)
	elseif mode == "playing" then
		local state = installPlayer(library.albums[1])
		local spectrum = App.services.playback.spectrum
		App.page = App:pageFor(route)
		warm(120)
		run("playing " .. pageName, frames, function(at)
			state.at = 30 + at / 60
			for band = 1, #spectrum.levels do spectrum.levels[band] = 0.5 + 0.4 * math.sin(at / 7 + band) end
		end, function()
			App:tick(now(), window)
			if window.shouldRedraw then
				window.shouldRedraw = false
				ui:frame(window)
			end
		end)
	elseif mode == "idle" then
		run("idle " .. pageName, frames, nil, function()
			App:tick(now(), window)
			if window.shouldRedraw then
				window.shouldRedraw = false
				ui:frame(window)
			end
		end)
	else
		error("unknown BEAT_BENCH_MODE " .. mode)
	end

	local rest = heapKiB()
	print(string.format("heap at rest %8.0f KiB (%.1f MiB)", rest, rest / 1024))

	screen:close()
	App.services.playback.player:close()
	fs.rmdir(config)
	return
end

local pages = {
	{ kind = "home" },
	{ kind = "library" },
	{ kind = "album", id = library.albums[1].id },
	{ kind = "artist", id = library.artists[1].id },
	{ kind = "playlists" },
	{ kind = "settings" }
}

for _, route in ipairs(pages) do
	App.page = App:pageFor(route)
	viewTime = 0
	local cold = now()
	draw()
	results[#results + 1] = { label = "first frame " .. route.kind, frames = 1, perFrame = (now() - cold) * 1000, viewPerFrame = viewTime * 1000, heap = heapKiB() }
	settleCovers()
	scenario("redraw " .. route.kind, 60, nil, draw)
end

App.page = App:pageFor({ kind = "library" })
settleCovers()
local key = App:pageKey()
scenario("scroll library grid", 240, function(frame)
	App.services.scroll.offsets[key] = frame * 40
	if frame % 8 == 0 then App.services.covers:step(now()) end
end, draw)

App.services.settings.values.view = "list"
App.services.scroll.offsets[key] = 0
scenario("scroll library list", 240, function(frame)
	App.services.scroll.offsets[key] = frame * 40
end, draw)
App.services.settings.values.view = "grid"
App.services.scroll.offsets[key] = 0

-- The pointer swept over the grid, a move per frame: every move is a view, a solve and a draw.
local window = screen.window
scenario("hover library grid", 240, function(frame)
	screen:event({ name = "mouseMove", window = window, x = 300 + (frame * 37) % 1000, y = 200 + (frame * 13) % 600 })
end, draw)
screen:event({ name = "mouseLeave", window = window })

-- The pointer down the desktop rail: the sidebar's hover hit test runs on every move, and a
-- playlist row it lands on shows the name in a tooltip over the page.
scenario("hover sidebar", 240, function(frame)
	screen:event({ name = "mouseMove", window = window, x = 40 + (frame * 11) % 140, y = 120 + (frame * 17) % 640 })
end, draw)
screen:event({ name = "mouseLeave", window = window })

-- Opening one album after another, as clicks on the grid do: each is a page the app has not shown.
scenario("navigate albums", 60, function(frame)
	local album = library.albums[(frame * 7) % #library.albums + 1]
	App:act({ type = "navigate", page = { kind = "album", id = album.id } })
end, draw)
scenario("navigate artists", 60, function(frame)
	local artist = library.artists[(frame * 7) % #library.artists + 1]
	App:act({ type = "navigate", page = { kind = "artist", id = artist.id } })
end, draw)

App.page = App:pageFor({ kind = "search" })
local typed = "the night"
scenario("search typing", #typed, function(frame)
	App:act({ type = "search", value = typed:sub(1, frame) })
end, draw)
scenario("redraw search results", 60, nil, draw)
App:act({ type = "search", value = "" })

App.page = App:pageFor({ kind = "home" })
App.services.motion.clock.reduce = false
local slideStart = now()
scenario("page slide", 64, function(frame)
	App.services.motion:slide(1, slideStart - frame / 64 * 0.28)
end, draw)

-- A track playing on the home page, as the window loop runs it: the ticker steps the services, and
-- whatever they changed is drawn. The audio is a stand-in whose playhead moves a frame at a time,
-- and the spectrum is given new levels every frame as the decoder would.
do
	local state = installPlayer(library.albums[1])
	App.page = App:pageFor({ kind = "home" })
	settleCovers()
	local spectrum = App.services.playback.spectrum
	local window = screen.window
	local builds = 0
	scenario("playing, 240 ticks", 240, function(frame)
		state.at = 30 + frame / 60
		for band = 1, #spectrum.levels do spectrum.levels[band] = 0.5 + 0.4 * math.sin(frame / 7 + band) end
		local before = viewTime
		App:tick(now(), window)
		if window.shouldRedraw then
			window.shouldRedraw = false
			ui:frame(window)
		end
		if viewTime ~= before then builds = builds + 1 end
	end, function() end)
	results[#results].label = string.format("playing (%d builds)", builds)

	-- The pointer along the player bar: its controls, the seek slider and the volume a phone's bar
	-- does not have, all while a track plays.
	scenario("hover player bar", 240, function(frame)
		screen:event({ name = "mouseMove", window = window, x = 200 + (frame * 29) % 1000, y = window.height - 30 })
	end, draw)
	screen:event({ name = "mouseLeave", window = window })

	App:open("now_playing")
	App.services.motion.clock:set("nowPlaying", 1)
	settleCovers()
	scenario("now playing overlay", 60, nil, draw)
	App:close("now_playing")
end

local totalMs = (now() - startedAt) * 1000

print(string.format("require beat.app  %8.1f ms", (requiredAt - startedAt) * 1000))
print(string.format("App:init          %8.1f ms", (initAt - requiredAt) * 1000))
print(string.format("screen (gpu+font)%8.1f ms", screenMs))
print(string.format("first frame       %8.1f ms", firstFrame))
print(string.format("heap at start     %8.0f KiB", baseline))
print(string.format("heap after init   %8.0f KiB", heapAfterInit))
print(string.format("library           %d tracks, %d albums", #library.tracks, #library.albums))
print()
print(string.format("%-28s %6s %10s %10s %10s", "scenario", "frames", "ms/frame", "view ms", "heap KiB"))
for _, r in ipairs(results) do
	print(string.format("%-28s %6d %10.2f %10.2f %10.0f", r.label, r.frames, r.perFrame, r.viewPerFrame, r.heap))
end
print(string.format("total %.0f ms", totalMs))

screen:close()
App.services.playback.player:close()
fs.rmdir(config)
