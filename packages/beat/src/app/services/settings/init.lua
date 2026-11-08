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
---@field dirtyAt number? # When the deferred save is due; nil when disk has the current values
local Settings = {}
Settings.__index = Settings
Settings.needs = { "settingsValues" }
Settings.handles = { "sidebarWidth", "toggleSidebar", "pluginEnabled" }

---@param deps { settingsValues: beat.Settings }?
---@return beat.SettingsService
function Settings.new(deps)
	return setmetatable({ values = deps and deps.settingsValues or settingsModel.load(), dirtyAt = nil }, Settings)
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

-- The settings screen's sidebar controls. Both redraw through the message that carried them.
function Settings:update(message)
	if message.type == "sidebarWidth" then
		self.values.sidebarWidth = math.max(200, math.min(360, message.width or 264))
	elseif message.type == "toggleSidebar" then
		self.values.sidebarCollapsed = not self.values.sidebarCollapsed
	elseif message.type == "pluginEnabled" then
		if type(message.file) ~= "string" or message.file == "" then return end
		local list = self.values.disabledPlugins
		local at = nil
		for index, name in ipairs(list) do
			if name == message.file then at = index end
		end
		-- The plugins page's switch says what the next start should load. The entry is the file
		-- name in the plugins folder: a file that will not load can be switched off too, and a
		-- switched-off file is never run. Nothing is loaded or unloaded now: the plugin that is
		-- running keeps running until beat is started again.
		if message.enabled == false then
			if at == nil then list[#list + 1] = message.file end
		elseif at ~= nil then
			table.remove(list, at)
		end
	else
		return
	end
	self:changed()
end

function Settings:step(now)
	if self.dirtyAt ~= nil and now >= self.dirtyAt then self:save() end
end

--- The window is closing: a change still settling is written now rather than lost.
function Settings:flush()
	if self.dirtyAt ~= nil then self:save() end
end

return Settings
