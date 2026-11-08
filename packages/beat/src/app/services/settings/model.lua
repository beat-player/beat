-- The few things a launch remembers. This is not a library cache: no track, tag, picture or
-- play history is written. It is the folder a person chose, how they like the screen, and the
-- volume they left it at.
local fs = require("fs")
local path = require("path")
local json = require("json")
local paths = require("beat.paths")

local settings = {}

---@class beat.Settings
---@field root string?
---@field theme string
---@field accent string # A preset name, or a custom #rrggbb colour
---@field volume number
---@field isMuted boolean
---@field sort string
---@field view "grid"|"list"
---@field sidebarWidth number
---@field sidebarCollapsed boolean
---@field uiScale number
---@field reduceMotion boolean
---@field lastfmSessionKey string
---@field lastfmUsername string
---@field lastfmEnabled boolean
---@field equalizerPreset string? # As the file holds it: the equalizer service validates it at start
---@field equalizerGains number[]?
---@field equalizerCustomPresets beat.EqualizerCustomPreset[]?
---@field disabledPlugins string[] # Plugin files switched off by name; applied at the next start

---@type beat.Settings
local DEFAULTS = {
	root = nil,
	theme = "night",
	accent = "lime",
	volume = 0.8,
	isMuted = false,
	sort = "title",
	view = "grid",
	sidebarWidth = 264,
	sidebarCollapsed = false,
	uiScale = 1,
	reduceMotion = false,
	lastfmSessionKey = "",
	lastfmUsername = "",
	lastfmEnabled = true,
	equalizerPreset = "flat",
	equalizerGains = { 0, 0, 0, 0, 0 },
	equalizerCustomPresets = {},
	disabledPlugins = {}
}

---@param value any
---@param fallback number
local function number(value, fallback)
	if type(value) ~= "number" or value ~= value then return fallback end
	return value
end

--- The file names of switched-off plugins. Anything but a string in the list is not a name and is
--- dropped, the same way a colour or a folder of the wrong type falls back to its default.
---@param value any
---@return string[]
local function pluginNames(value)
	if type(value) ~= "table" then return {} end
	local names = {}
	for _, name in ipairs(value) do
		if type(name) == "string" and name ~= "" then names[#names + 1] = name end
	end
	return names
end

---@param dir string?
---@return beat.Settings
---@return string
function settings.load(dir)
	local file = paths.file("settings.json", dir)
	local data = {}

	local bytes = fs.read(file)
	if bytes ~= nil then
		local ok, parsed = pcall(|| -> json.decode(bytes):unpack())
		if ok and type(parsed) == "table" then data = parsed end
	end

	---@type beat.Settings
	local loaded = {
		root = type(data.root) == "string" and data.root or nil,
		theme = type(data.theme) == "string" and data.theme or DEFAULTS.theme,
		accent = type(data.accent) == "string" and data.accent or DEFAULTS.accent,
		volume = math.max(0, math.min(1, number(data.volume, DEFAULTS.volume))),
		isMuted = data.isMuted == true,
		sort = type(data.sort) == "string" and data.sort or DEFAULTS.sort,
		view = data.view == "list" ? "list" : "grid",
		sidebarWidth = math.max(200, math.min(360, number(data.sidebarWidth, DEFAULTS.sidebarWidth))),
		sidebarCollapsed = data.sidebarCollapsed == true,
		uiScale = math.max(0.75, math.min(1.5, number(data.uiScale, DEFAULTS.uiScale))),
		reduceMotion = data.reduceMotion == true,
		lastfmSessionKey = type(data.lastfmSessionKey) == "string" and data.lastfmSessionKey or "",
		lastfmUsername = type(data.lastfmUsername) == "string" and data.lastfmUsername or "",
		lastfmEnabled = data.lastfmEnabled ~= false,
		-- The equalizer keys are read as the file holds them. Their rules -- gains held to a range,
		-- custom presets named and counted, a preset that is gone falling back -- are about presets,
		-- so the equalizer service validates them when it starts, where those rules live.
		equalizerPreset = data.equalizerPreset,
		equalizerGains = data.equalizerGains,
		equalizerCustomPresets = data.equalizerCustomPresets,
		disabledPlugins = pluginNames(data.disabledPlugins)
	}

	return loaded, file
end

---@param value beat.Settings
---@param dir string?
---@return boolean
---@return string?
function settings.save(value, dir)
	local file = paths.file("settings.json", dir)
	local folder = path.dirname(file)

	if not fs.isdir(folder) then
		fs.mkdirAll(folder)
		if not fs.isdir(folder) then
			return false, "cannot create " .. folder
		end
	end

	local ok, encoded = pcall(json.encode, value)
	if not ok then return false, tostring(encoded) end

	if not fs.write(file, encoded) then
		return false, "cannot write " .. file
	end

	-- The file can hold a Last.fm session key, which can act on that account. Keep it private to
	-- the account that runs beat; Windows uses the user profile's own ACLs instead.
	if jit == nil or jit.os ~= "Windows" then fs.chmod(file, 384) end

	return true
end

return settings
