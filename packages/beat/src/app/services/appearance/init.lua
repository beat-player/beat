-- The theme, and the crossfade from the one before it. A theme is remade from the settings
-- whenever the listener picks a different one; the old theme's colours are kept for a moment and
-- mixed in frame by frame, so the screen turns rather than blinking. The accent picker turns the
-- crossfade off: its colours change under the pointer and trailing them would lag the hand.
--
-- The palette module beside this file is private: a view reads the live theme from `theme` and
-- asks this service which themes and accents exist, so the choices and the instance they make
-- stay in one place.
local wonderland = require("wonderland")
local theme = require("beat.app.services.appearance.theme")

local time = wonderland.time

local FADE_TIME = 0.22

---@class beat.AppearanceService
---@field theme beat.Theme
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
		theme = theme.new(values.theme, values.accent, values.uiScale),
		fade = nil,
	}, Appearance)
end

-- The theme names the settings screen offers, in the order it shows them.
---@return string[]
function Appearance:names()
	return theme.names()
end

-- The preset accents, before a custom colour is added to the picker by hand.
---@return string[]
function Appearance:accents()
	return theme.accents()
end

--- What an accent name or `#rrggbb` value looks like, so a picker can show a choice before it is
--- applied rather than reading it back from the live theme.
---@param name string
---@return string
function Appearance:accentColour(name)
	return theme.accentColour(name)
end

--- The ink that reads on `name`'s colour.
---@param name string
---@return string
function Appearance:accentInk(name)
	return theme.accentInk(name)
end

---@param animate boolean? # False for a live picker, whose turns should not trail the pointer
function Appearance:change(animate)
	local previous = self.theme
	local values = self.settings.values
	self.theme = theme.new(values.theme, values.accent, values.uiScale)

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
	local progress = self.motion:progress(self.fade.start, FADE_TIME, now, self.motion.ease.inOutCubic)
	-- Quantised so the crossfade reuses styles rather than interning a colour a frame.
	self.theme.mix = math.floor(progress * 32 + 0.5) / 32
	if progress >= 1 then
		self.theme.fromColors = nil
		self.fade = nil
	end
	return true, self.fade ~= nil
end

return Appearance
