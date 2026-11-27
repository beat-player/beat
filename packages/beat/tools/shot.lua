-- A headless screenshot of the app, so a change to a page, an overlay or the first launch can be
-- looked at without a person running the player. The app is built against a throwaway copy of a
-- config directory, laid out and drawn offscreen, and the last frame is written as a PNG.
--
--   lde run tools/shot.lua -- /tmp/shots/home.png
--   SHOT_PAGE=settings SHOT_THEME=light lde run tools/shot.lua -- /tmp/shots/settings.png
--   SHOT_OVERLAY=playlist_picker SHOT_OVERLAY_PARAMS='{"kind":"track","id":1}' SHOT_ROOT=/tmp \
--     lde run tools/shot.lua -- /tmp/shots/picker.png
--
-- The output path is the first argument, or SHOT_OUT:
--   SHOT_WIDTH / SHOT_HEIGHT   window in physical pixels (default 1200 x 688)
--   SHOT_DENSITY               physical pixels per density-independent pixel (default 1; a phone
--                              also gets the system bars' insets, as the bench gives it)
--   SHOT_PAGE                  starts on home, library, library-list, playlists, settings,
--                              search or folders; default is the page the app opens on
--   SHOT_OVERLAY               opens this overlay over the page, e.g. playlist_picker
--   SHOT_OVERLAY_PARAMS        a JSON object handed to the overlay, e.g. {"kind":"track","id":1}
--   SHOT_CONFIG                config directory to copy into a temp one; default is an empty
--                              config, which shows the first launch (the folder browser)
--   SHOT_ROOT                  writes this root into the copied settings before the app starts,
--                              so the shell is the usual one without a scan being started
--   SHOT_THEME                 dark or light (or a palette name: night, day, amoled)
--   SHOT_FRAMES                frames drawn before saving, so decodes finish (default 30)
local fs = require("fs")
local path = require("path")
local json = require("json")
local wonderland = require("wonderland")
local paths = require("beat.paths")

---@param name string
---@param fallback number
local function numberEnv(name, fallback)
	local text = os.getenv(name)
	if text == nil or text == "" then return fallback end
	local value = tonumber(text)
	if value == nil then error("shot: " .. name .. " is not a number: " .. text) end
	return value
end

local out = tostring(select(1, ...) or os.getenv("SHOT_OUT") or "")
if out == "" then error("shot: no output path (pass one after --, or set SHOT_OUT)") end

local width = numberEnv("SHOT_WIDTH", 1200)
local height = numberEnv("SHOT_HEIGHT", 688)
local frames = math.max(1, numberEnv("SHOT_FRAMES", 30))
local densityText = os.getenv("SHOT_DENSITY")
local density = numberEnv("SHOT_DENSITY", 1)
local pageName = os.getenv("SHOT_PAGE")
local overlayName = os.getenv("SHOT_OVERLAY")
local overlayParamsText = os.getenv("SHOT_OVERLAY_PARAMS")
local configSource = os.getenv("SHOT_CONFIG")
local root = os.getenv("SHOT_ROOT")
local themeName = os.getenv("SHOT_THEME")

-- The phone's geometry is the bench's: the display density makes a length in the theme's units
-- that many physical pixels, and the system bars cover a strip of the window top and bottom.
if densityText ~= nil and densityText ~= "" then
	local inset = math.floor(24 * density + 0.5)
	require("beat.platform").screen = function() return { density = density, top = inset, bottom = inset } end
end

-- A config directory of its own: the app writes logs and settings as it starts, and the real
-- one is not touched. A copy keeps the library and playlists a caller wants to see.
local config = os.tmpname() .. "-beat-shot"
os.remove(config)
fs.mkdirAll(config)
if configSource ~= nil and configSource ~= "" then
	if not fs.isdir(configSource) then error("shot: SHOT_CONFIG is not a directory: " .. configSource) end
	if not fs.copy(configSource, config) then error("shot: could not copy " .. configSource .. " to " .. config) end
end
paths.directory = function() return config end

-- Settings are read once, inside App:init, so the argv/env choices are written into the copied
-- settings file before the app exists. Reducing motion makes a shot the settled end of every
-- animation rather than whichever frame the tool happened to catch.
local overrides = { reduceMotion = true }
if root ~= nil and root ~= "" then overrides.root = root end
if themeName ~= nil and themeName ~= "" then
	overrides.theme = themeName == "dark" and "night" or themeName == "light" and "day" or themeName
end
local settingsFile = path.join(config, "settings.json")
local stored = {}
local bytes = fs.read(settingsFile)
if bytes ~= nil then
	local ok, decoded = pcall(function() return json.decode(bytes):unpack() end)
	if ok and type(decoded) == "table" then stored = decoded end
end
for key, value in pairs(overrides) do stored[key] = value end
fs.write(settingsFile, json.encode(stored))

require("beat.app.services.scan.job").start = function() error("the screenshot tool does not scan") end
local App = require("beat.app")

-- The renderer is offscreen and needs no display, but a build without the render plugin must say
-- so rather than fail somewhere inside the shell.
do
	local ok = pcall(function()
		wonderland.headless.new(function() return wonderland.div() end, { width = 8, height = 8 }):close()
	end)
	if not ok then error("shot: this build cannot render offscreen (the headless renderer would not open)") end
end

App:init({ scan = false })

---@type table<string, beat.Route>
local routes = {
	home = { kind = "home" },
	library = { kind = "library" },
	["library-list"] = { kind = "library" },
	playlists = { kind = "playlists" },
	settings = { kind = "settings" },
	search = { kind = "search" },
	folders = { kind = "folders" }
}
if pageName ~= nil and pageName ~= "" then
	local route = assert(routes[pageName], "shot: unknown SHOT_PAGE " .. pageName) --[[@as beat.Route]]
	App.services.settings.values.view = pageName == "library-list" and "list" or "grid"
	App.page = App:pageFor(route)
end

if overlayName ~= nil and overlayName ~= "" then
	local params = {}
	if overlayParamsText ~= nil and overlayParamsText ~= "" then
		local ok, decoded = pcall(function() return json.decode(overlayParamsText):unpack() end)
		if not ok or type(decoded) ~= "table" then
			error("shot: SHOT_OVERLAY_PARAMS is not a JSON object: " .. overlayParamsText)
		end
		params = decoded
	end
	local opened = App:open(overlayName, params)
	if opened == nil then error("shot: the overlay " .. overlayName .. " refused to open with " .. json.encode(params)) end
end

local screen = wonderland.headless.new(function(window, assets)
	App.window = window
	App.assets = assets
	App.services.covers:use(assets)
	return require("beat.app.shell").view(App, window)
end, { width = width, height = height })
App.layoutPlugin = screen.plugins.layout
App.uiPlugin = screen.plugins.ui
App.window = screen.window

--- Lets the cover service decode what the page asked for, as the ticker would between frames.
local function settleCovers()
	for _ = 1, 200 do
		local _, busy = App.services.covers:step(wonderland.time.now())
		if not busy then break end
	end
end

for _ = 1, frames do
	screen:draw()
	settleCovers()
end
screen:draw()

local folder = path.dirname(out)
if folder ~= "" and folder ~= "." then fs.mkdirAll(folder) end
local ok, err = screen:save(out)
if not ok then error("shot: could not save " .. out .. ": " .. tostring(err)) end

screen:close()
App.services.playback.player:close()
fs.rmdir(config)
print(out)
