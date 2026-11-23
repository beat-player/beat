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
local platform = require("beat.platform")

local time = wonderland.time

local FADE_TIME = 0.22

-- How often an automatic theme looks at the clock. The hour turns once, so a check every few
-- seconds would only be arithmetic; half a minute also lets the turn land soon after it happens.
local AUTO_CHECK = 30

local DAY_START = 7
local NIGHT_START = 19

--- The palette a theme setting means. `auto` follows the clock, so it is resolved here rather
--- than in the file: a launch at noon and the same launch at midnight read the same setting and
--- still get the light or the dark screen they should.
---@param name string
---@return string
local function resolveName(name)
	if name ~= "auto" then return name end
	local hour = os.date("*t") --[[@as osdate]].hour
	return hour >= DAY_START and hour < NIGHT_START and "day" or "night"
end

--- The theme for the settings: the listener's UI scale, times the screen's density, so a phone at
--- 2.6 pixels a point draws the same physical sizes a desktop draws at 1.
---@param values beat.Settings
---@return beat.Theme
local function themeFor(values)
	return theme.new(resolveName(values.theme), values.accent, values.uiScale * platform.screen().density)
end

---@class beat.AppearanceService: beat.Service
---@field settings beat.SettingsService
---@field motion beat.MotionService
---@field theme beat.Theme
---@field autoResolved string # the palette `auto` resolved to, so a turn of the clock can be noticed
---@field checkedAt number? # when an automatic theme last looked at the clock
---@field fade { start: number }?
local Appearance = {}
Appearance.__index = Appearance
Appearance.needs = { "settings", "motion" }

---@param deps { settings: beat.SettingsService, motion: beat.MotionService }
---@return beat.AppearanceService
function Appearance.new(deps)
	local values = deps.settings.values
	local current = themeFor(values)
	return setmetatable(
		{
			settings = deps.settings,
			motion = deps.motion,
			theme = current,
			autoResolved = current.name,
			checkedAt = nil,
			fade = nil
		},
		Appearance
	)
end

-- The theme names the settings screen offers, in the order it shows them. `auto` is a choice
-- rather than a palette, so it is put in front here and never reaches the palette module.
---@return string[]
function Appearance:names()
	local list = { "auto" }
	for _, name in ipairs(theme.names()) do list[#list + 1] = name end
	return list
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
	self.theme = themeFor(values)
	self.autoResolved = self.theme.name

	if animate ~= false and previous ~= nil and not self.motion.clock.reduce then
		self.theme.fromColors = previous.colors
		self.theme.mix = 0
		self.fade = { start = time.now() }
	else
		self.fade = nil
	end

	self.settings:changed()
end

--- The settings screen's appearance controls. Each writes its key and then remakes the theme, so
--- the screen turns as the control is used.
Appearance.on = {
	---@param self beat.AppearanceService
	---@param message beat.ThemeMessage
	theme = function(self, message)
		self.settings.values.theme = message.name
		self:change()
	end,

	---@param self beat.AppearanceService
	---@param message beat.AccentMessage
	accent = function(self, message)
		self.settings.values.accent = message.name
		self:change()
	end,

	---@param self beat.AppearanceService
	---@param message beat.UiScaleMessage
	uiScale = function(self, message)
		self.settings.values.uiScale = message.value
		self:change()
	end
}

function Appearance:step(now)
	-- An automatic theme is remade when the clock reaches the other side of the day, and checked
	-- at an interval rather than every tick: the hour is not something to read sixty times a second.
	local changed = false
	if self.settings.values.theme == "auto" and (self.checkedAt == nil or now - self.checkedAt >= AUTO_CHECK) then
		self.checkedAt = now
		if resolveName("auto") ~= self.autoResolved then
			self:change()
			changed = true
		end
	end

	if self.fade == nil then return changed, false end
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
