-- The few things a launch remembers. This is not a library cache: no track, tag, picture or
-- play history is written. It is the folder a person chose, how they like the screen, and the
-- volume they left it at.
local fs = require("fs")
local path = require("path")
local json = require("json")
local equalizer = require("beat.app.services.playback.equalizer")

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
---@field equalizerPreset string
---@field equalizerGains number[]
---@field equalizerCustomPresets beat.EqualizerCustomPreset[]

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
equalizerGains = { 0, 0, 0, 0, 0},
equalizerCustomPresets = {},
}

---@return string
function settings.directory()
	local osName = jit and jit.os or ""
	local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "."

	if osName == "Windows" then
		return path.join(os.getenv("APPDATA") or home, "beat")
	elseif osName == "OSX" then
		return path.join(home, "Library", "Application Support", "beat")
	end

	return path.join(os.getenv("XDG_CONFIG_HOME") or path.join(home, ".config"), "beat")
end

---@param dir string?
---@return string
function settings.file(dir)
	return path.join(dir or settings.directory(), "settings.json")
end

---@param value any
---@param fallback number
---@return number
local function number(value, fallback)
	if type(value) ~= "number" or value ~= value then return fallback end
	return value
end

---@param dir string?
---@return beat.Settings
---@return string
function settings.load(dir)
	local file = settings.file(dir)
	local data = {}

	local bytes = fs.read(file)
	if bytes ~= nil then
		local ok, parsed = pcall(function() return json.decode(bytes):unpack() end)
		if ok and type(parsed) == "table" then data = parsed end
	end

	local preset = type(data.equalizerPreset) == "string" and data.equalizerPreset or "flat"
	local customs = {}
	local used = {}
	for _, builtin in ipairs(equalizer.presets) do
			used[builtin.name] = true
			used[builtin.id] = true
		end
	if type(data.equalizerCustomPresets) == "table" then
		for _, item in ipairs(data.equalizerCustomPresets) do
				if type(item) == "table" and type(item.name) == "string" and item.name ~= ""
				and not used[item.name] and #customs < 32 then
					customs[#customs + 1] = { name = item.name, gains = equalizer.sanitize(item.gains)}
					used[item.name] = true
				end
			end
	end
	local custom
	for _, entry in ipairs(customs) do
			if preset == entry.name then custom = entry end
		end
	local gains = data.equalizerGains ~= nil and equalizer.sanitize(data.equalizerGains)
	or (custom ~= nil and equalizer.copyGains(custom.gains)) or equalizer.presetGains(preset)
	if equalizer.preset(preset) == nil and custom == nil then
		preset = type(data.equalizerGains) == "table" and "custom" or "flat"
	end

	---@type beat.Settings
	local loaded = {
	root = type(data.root) == "string" and data.root or nil,
	theme = type(data.theme) == "string" and data.theme or DEFAULTS.theme,
	accent = type(data.accent) == "string" and data.accent or DEFAULTS.accent,
	volume = math.max(0, math.min(1, number(data.volume, DEFAULTS.volume))),
	isMuted = data.isMuted == true,
	sort = type(data.sort) == "string" and data.sort or DEFAULTS.sort,
	view = data.view == "list" and "list" or "grid",
	sidebarWidth = math.max(200, math.min(360, number(data.sidebarWidth, DEFAULTS.sidebarWidth))),
	sidebarCollapsed = data.sidebarCollapsed == true,
	uiScale = math.max(0.75, math.min(1.5, number(data.uiScale, DEFAULTS.uiScale))),
	reduceMotion = data.reduceMotion == true,
	lastfmSessionKey = type(data.lastfmSessionKey) == "string" and data.lastfmSessionKey or "",
	lastfmUsername = type(data.lastfmUsername) == "string" and data.lastfmUsername or "",
	lastfmEnabled = data.lastfmEnabled ~= false,
	equalizerPreset = preset,
	equalizerGains = gains,
	equalizerCustomPresets = customs,
	}

	return loaded, file
end

---@param value beat.Settings
---@param dir string?
---@return boolean
---@return string?
function settings.save(value, dir)
	local file = settings.file(dir)
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
