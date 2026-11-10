-- The settings file: every value the app remembers about how the listener likes it, and the one
-- place that decides when those values reach disk. Changes come in bursts -- a drag of the volume,
-- a live colour picker -- so writing is put off until the hand has been still for a moment rather
-- than done on every message. Everything else reads `values`; nothing saves on its own.
local wonderland = require("wonderland")
local Log = require("beat.log")
local settingsModel = require("beat.app.services.settings.model")

local time = wonderland.time

-- Long enough that a drag or a picker's turns make one write instead of dozens.
local SAVE_DELAY = 0.6

---@class beat.SettingsService: beat.Service
---@field values beat.Settings
---@field registry beat.Registry?
---@field toasts beat.ToastsService?
---@field dirtyAt number? # When the deferred save is due; nil when disk has the current values
local Settings = {}
Settings.__index = Settings
Settings.needs = { "settingsValues", "registry", "toasts" }

---@param deps { settingsValues: beat.Settings, registry: beat.Registry?, toasts: beat.ToastsService? }?
---@return beat.SettingsService
function Settings.new(deps)
	deps = deps or {}
	return setmetatable(
		{
			values = deps.settingsValues or settingsModel.load(),
			registry = deps.registry,
			toasts = deps.toasts,
			dirtyAt = nil
		},
		Settings
	)
end

--- A plugin's values as the app reads them: what the file holds, with the defaults its settings
--- definition names filled in for anything it has never changed. The table is the one the service
--- keeps, so repeated calls are the same table; a change is a `pluginSetting` message rather than
--- an edit here, because the service is what saves.
---@param name string
---@return table<string, any>
function Settings:plugin(name)
	local stored = self.values.plugins[name]
	if type(stored) ~= "table" then
		stored = {}
		self.values.plugins[name] = stored
	end

	local definition = self.registry ~= nil and self.registry.settingsByName[name] or nil
	if definition ~= nil then
		for key, value in pairs(definition.defaults) do
			if stored[key] == nil then stored[key] = value end
		end
	end
	return stored
end

---@param text string
function Settings:refuse(text)
	if self.toasts ~= nil then self.toasts:show(text, "error") end
end

--- A value changed: save once the changes settle.
function Settings:changed()
	self.dirtyAt = time.now() + SAVE_DELAY
end

-- A failure is logged rather than shown: a read-only config directory must not interrupt playback.
function Settings:save()
	local ok, err = settingsModel.save(self.values, nil)
	if not ok then Log.write("error", "settings could not be saved: " .. tostring(err)) end
	self.dirtyAt = nil
end

-- The settings screen's controls: each value is saved once the changes settle, and the message that
-- carried it is what redraws the screen.
Settings.on = {
	---@param self beat.SettingsService
	---@param message beat.SidebarWidthMessage
	sidebarWidth = function(self, message)
		self.values.sidebarWidth = math.max(200, math.min(360, message.width or 264))
		self:changed()
	end,

	---@param self beat.SettingsService
	---@param message beat.ToggleSidebarMessage
	toggleSidebar = function(self, message)
		self.values.sidebarCollapsed = not self.values.sidebarCollapsed
		self:changed()
	end,

	---@param self beat.SettingsService
	---@param message beat.MinimizeToTrayMessage
	minimizeToTray = function(self, message)
		self.values.minimizeToTray = message.value == true
		self:changed()
	end,

	--- The plugins page's switch says what the next start should load. The entry is the file name
	--- in the plugins folder: a file that will not load can be switched off too, and a switched-off
	--- file is never run. Nothing is loaded or unloaded now: the plugin that is running keeps
	--- running until beat is started again.
	---@param self beat.SettingsService
	---@param message beat.PluginEnabledMessage
	pluginEnabled = function(self, message)
		if type(message.file) ~= "string" or message.file == "" then return end
		local list = self.values.disabledPlugins
		local at = nil
		for index, name in ipairs(list) do
			if name == message.file then at = index end
		end
		if message.enabled == false then
			if at == nil then list[#list + 1] = message.file end
		elseif at ~= nil then
			table.remove(list, at)
		end
		self:changed()
	end,

	--- A plugin's value goes into the table the file holds, under the plugin's name; it is written
	--- with everything else once the changes settle.
	---@param self beat.SettingsService
	---@param message beat.PluginSettingMessage
	pluginSetting = function(self, message)
		if type(message.plugin) ~= "string" or message.plugin == "" then
			self:refuse("A plugin setting needs a plugin name")
			return
		end
		if type(message.key) ~= "string" or message.key == "" then
			self:refuse("A plugin setting needs a key")
			return
		end
		if not settingsModel.isJSONValue(message.value) then
			self:refuse("Plugin " .. message.plugin .. " tried to save a value that is not JSON")
			return
		end

		local values = self.values.plugins[message.plugin]
		if type(values) ~= "table" then
			values = {}
			self.values.plugins[message.plugin] = values
		end
		values[message.key] = message.value
		self:changed()
	end
}

function Settings:step(now)
	if self.dirtyAt ~= nil and now >= self.dirtyAt then self:save() end
end

--- The window is closing: a change still settling is written now rather than lost.
function Settings:flush()
	if self.dirtyAt ~= nil then self:save() end
end

return Settings
