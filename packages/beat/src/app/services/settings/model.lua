-- The few things a launch remembers. This is not a library cache: no track, tag, picture or
-- play history is written. It is the folder a person chose, how they like the screen, and the
-- volume they left it at.
local fs = require("fs")
local path = require("path")
local json = require("json")
local paths = require("beat.paths")
local autoeq = require("beat.app.services.equalizer.autoeq")
local bands = require("beat.app.services.equalizer.bands")

local settings = {}

---@class beat.Settings
---@field root string?
---@field theme string # A palette name, or "auto" to follow the clock (the appearance service resolves it)
---@field accent string # A preset name, or a custom #rrggbb colour
---@field volume number
---@field isMuted boolean
---@field pauseForOtherAudio boolean # Pausing for another app's audio and for a silent media stream
---@field sort string
---@field view "grid"|"list"
---@field sidebarWidth number
---@field sidebarCollapsed boolean
---@field uiScale number
---@field reduceMotion boolean
---@field minimizeToTray boolean # Minimizing sends the window to the tray instead of the taskbar
---@field updateChannel "release"|"nightly"|nil # nil follows the build that is installed
---@field checkUpdates boolean # Look for a newer build once a launch
---@field lastfmSessionKey string
---@field lastfmUsername string
---@field lastfmEnabled boolean
---@field equalizerPreset string? # As the file holds it: the equalizer service validates it at start
---@field equalizerGains number[]?
---@field equalizerCustomPresets beat.EqualizerCustomPreset[]?
---@field equalizerPreamp number # The fader's own correction, in dB
---@field equalizerProfile beat.EqualizerProfile? # An imported AutoEq profile under the faders
---@field disabledPlugins string[] # Plugin files switched off by name; applied at the next start
---@field pluginDefaultsVersion number # The optional plugin list this file has been brought up to
---@field plugins table<string, table<string, any>> # A plugin's own values, by plugin name
---@field lastPage beat.SavedPage? # The page the last launch was on, as the app writes it down

-- The optional plugins that arrived after a settings file could already name its switches: a file
-- written before one of them existed never had the chance to say no to it, so it starts off there
-- too. The version is written with the file, which is what keeps the switch a person does turn on
-- from being turned off again at the next launch.
local PLUGIN_DEFAULTS_VERSION = 2
local INTRODUCED = { { name = "debug", since = 2 } }

---@type beat.Settings
local DEFAULTS = {
	root = nil,
	theme = "night",
	accent = "lime",
	volume = 0.8,
	isMuted = false,
	pauseForOtherAudio = true,
	sort = "title",
	view = "grid",
	sidebarWidth = 264,
	sidebarCollapsed = false,
	uiScale = 1,
	reduceMotion = false,
	minimizeToTray = false,
	-- Nothing is chosen at first, so a build follows its own line: a nightly keeps getting
	-- nightlies and a release keeps getting releases until someone asks for the other one.
	updateChannel = nil,
	checkUpdates = true,
	lastfmSessionKey = "",
	lastfmUsername = "",
	lastfmEnabled = true,
	equalizerPreset = "flat",
	equalizerGains = { 0, 0, 0, 0, 0 },
	equalizerCustomPresets = {},
	equalizerPreamp = 0,
	equalizerProfile = nil,
	-- A fresh install starts with the stars and the performance overlay off: both are extras some
	-- people want, not part of the player. A settings file that already names its switches keeps
	-- whatever it says, so someone who turned one on is not turned off by an update.
	disabledPlugins = { "ratings", "debug" },
	pluginDefaultsVersion = PLUGIN_DEFAULTS_VERSION,
	plugins = {},
	lastPage = nil
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

--- The switches a settings file without a `disabledPlugins` key starts from: the fresh-install
--- list, copied because the settings service changes the list it was given.
---@return string[]
local function defaultPluginNames()
	local names = {}
	for _, name in ipairs(DEFAULTS.disabledPlugins) do names[#names + 1] = name end
	return names
end

--- Adds the optional plugins a file was written before to its switches. A file that already
--- carries the current version has been asked about all of them, including one a person turned
--- on, and is left as it is.
---@param data table
---@param names string[]
local function addIntroduced(data, names)
	local version = type(data.pluginDefaultsVersion) == "number" and data.pluginDefaultsVersion or 1
	for _, plugin in ipairs(INTRODUCED) do
		if version < plugin.since then
			local present = false
			for _, name in ipairs(names) do
				if name == plugin.name then
					present = true
					break
				end
			end
			if not present then names[#names + 1] = plugin.name end
		end
	end
end

--- A value a plugin can keep: what JSON holds, and nothing else. A table is either a list of
--- whole-number keys from one or an object of string keys; a metatable or a cycle is not
--- something JSON can write, and neither is a number with no finite value.
---@param value any
---@param seen table<table, boolean>?
local function serialisable(value, seen)
	if value == json.null then return false end
	local kind = type(value)
	if kind == "nil" or kind == "string" or kind == "boolean" then return true end
	if kind == "number" then return value == value and value ~= math.huge and value ~= -math.huge end
	if kind ~= "table" then return false end

	seen = seen or {}
	if getmetatable(value) ~= nil or seen[value] then return false end
	seen[value] = true

	local numeric, strings, most = 0, 0, 0
	for key in pairs(value) do
		if type(key) == "number" then
			if key < 1 or key % 1 ~= 0 then
				seen[value] = nil
				return false
			end
			numeric += 1
			if key > most then most = key end
		elseif type(key) == "string" then
			strings += 1
		else
			seen[value] = nil
			return false
		end
	end
	if (numeric > 0 and strings > 0) or (numeric > 0 and most ~= numeric) then
		seen[value] = nil
		return false
	end

	for _, child in pairs(value) do
		if not serialisable(child, seen) then
			seen[value] = nil
			return false
		end
	end
	seen[value] = nil
	return true
end

--- Whether a value can be written to settings.json and read back: the rule `pluginSetting`
--- messages are held to. `settings.isJSONValue` is the same check, for the settings service.
---@param value any
function settings.isJSONValue(value)
	return serialisable(value, {})
end

--- A plugin's values as the file holds them. An entry that is not a table, or holds something
--- JSON cannot hold, loads empty rather than stopping the settings file from being read at all.
--- Names are kept even when no plugin is loaded: a plugin that is gone for a run still finds its
--- values when it comes back.
---@param value any
---@return table<string, any>
local function pluginValues(value)
	if type(value) ~= "table" or not serialisable(value, {}) then return {} end
	return value
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

	---@type table<string, table<string, any>>
	local plugins = {}
	local stored = data.plugins
	if type(stored) == "table" then
		for name, value in pairs(stored) do
			if type(name) == "string" and name ~= "" then plugins[name] = pluginValues(value) end
		end
	end

	---@type beat.Settings
	local loaded = {
		root = type(data.root) == "string" and data.root or nil,
		theme = type(data.theme) == "string" and data.theme or DEFAULTS.theme,
		accent = type(data.accent) == "string" and data.accent or DEFAULTS.accent,
		volume = math.max(0, math.min(1, number(data.volume, DEFAULTS.volume))),
		isMuted = data.isMuted == true,
		-- A file written before the key existed, or by hand with anything but false, keeps pausing.
		pauseForOtherAudio = data.pauseForOtherAudio ~= false,
		sort = type(data.sort) == "string" and data.sort or DEFAULTS.sort,
		view = data.view == "list" ? "list" : "grid",
		sidebarWidth = math.max(200, math.min(360, number(data.sidebarWidth, DEFAULTS.sidebarWidth))),
		sidebarCollapsed = data.sidebarCollapsed == true,
		uiScale = math.max(0.75, math.min(1.5, number(data.uiScale, DEFAULTS.uiScale))),
		reduceMotion = data.reduceMotion == true,
		minimizeToTray = data.minimizeToTray == true,
		-- Only the two names mean anything; a file holding something else follows the build.
		updateChannel = (data.updateChannel == "release" or data.updateChannel == "nightly") and data.updateChannel or nil,
		checkUpdates = data.checkUpdates ~= false,
		lastfmSessionKey = type(data.lastfmSessionKey) == "string" and data.lastfmSessionKey or "",
		lastfmUsername = type(data.lastfmUsername) == "string" and data.lastfmUsername or "",
		lastfmEnabled = data.lastfmEnabled ~= false,
		-- The equalizer keys are read as the file holds them. Their rules -- gains held to a range,
		-- custom presets named and counted, a preset that is gone falling back -- are about presets,
		-- so the equalizer service validates them when it starts, where those rules live.
		equalizerPreset = data.equalizerPreset,
		equalizerGains = data.equalizerGains,
		equalizerCustomPresets = data.equalizerCustomPresets,
		-- Unlike the preset keys, these two are held to their ranges here: a preamp above the fader
		-- and a profile whose filters or name are not playable are the same reading every time, and
		-- the settings file a person edits by hand is exactly where they go wrong.
		equalizerPreamp = bands.clampPreamp(number(data.equalizerPreamp, 0)),
		equalizerProfile = autoeq.sanitize(data.equalizerProfile),
		-- A file that names its switches keeps them exactly; only one written before this key
		-- existed gets the fresh-install list, so turning ratings on is a switch that stays on.
		disabledPlugins = data.disabledPlugins == nil and defaultPluginNames() or pluginNames(data.disabledPlugins),
		pluginDefaultsVersion = PLUGIN_DEFAULTS_VERSION,
		plugins = plugins,
		-- The app validates what a route names when it opens it; a file written by another
		-- version, or by hand, is not trusted to name a page here.
		lastPage = type(data.lastPage) == "table" and data.lastPage or nil
	}

	-- A plugin the file was written before starts off there: the file has no word on a switch it
	-- never saw, and the overlay does not arrive on a screen that never chose it.
	addIntroduced(data, loaded.disabledPlugins)

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
