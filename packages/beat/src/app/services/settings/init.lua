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

---@class beat.SettingsService
---@field values beat.Settings
---@field dirtyAt number? # When the deferred save is due; nil when disk has the current values
local Settings = {}
Settings.__index = Settings
Settings.needs = {}
Settings.handles = { "sidebarWidth", "toggleSidebar" }

---@return beat.SettingsService
function Settings.new()
	return setmetatable({
		values = settingsModel.load(),
		dirtyAt = nil,
	}, Settings)
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
	else
		return
	end
	self:changed()
end

function Settings:step(now)
	if self.dirtyAt ~= nil and now >= self.dirtyAt then self:save() end
end

return Settings
