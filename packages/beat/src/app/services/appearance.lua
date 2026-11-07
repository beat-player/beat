-- The theme, and the crossfade from the one before it. A theme is remade from the settings
-- whenever the listener picks a different one; the old theme's colours are kept for a moment and
-- mixed in frame by frame, so the screen turns rather than blinking. The accent picker turns the
-- crossfade off: its colours change under the pointer and trailing them would lag the hand.
local wonderland = require("wonderland")
local ui = require("beat-ui")

local time = wonderland.time

local FADE_TIME = 0.22

---@class beat.AppearanceService
---@field theme beat.ui.Theme
---@field fade { start: number }?
local Appearance = {}
Appearance.__index = Appearance
Appearance.needs = { "settings", "motion" }
Appearance.handles = { "theme", "accent", "uiScale" }

---@param deps { settings: beat.SettingsService, motion: beat.MotionService }
---@return beat.AppearanceService
function Appearance.new(deps)
	local values = deps.settings.values
	return setmetatable({
		settings = deps.settings,
		motion = deps.motion,
		theme = ui.theme.new(values.theme, values.accent, values.uiScale),
		fade = nil,
	}, Appearance)
end

---@param animate boolean? # False for a live picker, whose turns should not trail the pointer
function Appearance:change(animate)
	local previous = self.theme
	local values = self.settings.values
	self.theme = ui.theme.new(values.theme, values.accent, values.uiScale)

	if animate ~= false and previous ~= nil and not self.motion.clock.reduce then
		self.theme.fromColors = previous.colors
		self.theme.mix = 0
		self.fade = { start = time.now() }
	else
		self.fade = nil
	end

	self.settings:changed()
end

-- The settings screen's appearance controls.
function Appearance:update(message)
	local values = self.settings.values
	if message.type == "theme" then
		values.theme = message.name
	elseif message.type == "accent" then
		values.accent = message.name
	elseif message.type == "uiScale" then
		values.uiScale = message.value
	else
		return
	end
	self:change()
end

function Appearance:step(now)
	if self.fade == nil then return false, false end
	local progress = ui.motion.progress(self.fade.start, FADE_TIME, now, ui.motion.ease.inOutCubic)
	-- Quantised so the crossfade reuses styles rather than interning a colour a frame.
	self.theme.mix = math.floor(progress * 32 + 0.5) / 32
	if progress >= 1 then
		self.theme.fromColors = nil
		self.fade = nil
	end
	return true, self.fade ~= nil
end

return Appearance
