-- Everything that moves between two values: the clock the always-moving parts read (the
-- now-playing cover's growth), and the page slide. Both are numbers a frame is drawn from, so
-- they are advanced by one ticker here rather than attached to the elements that show them.
--
-- The clock module beside this file is private: this service hands views the curves and the
-- one-shot progress they need, so a view never reaches past the ticker that owns the clock.
local wonderland = require("wonderland")
local clock = require("beat.app.services.motion.clock")

local time = wonderland.time

-- The slide's length. The shell reads its progress every frame, so every frame of it must be
-- drawn: `step` stays busy until it ends.
local SLIDE_TIME = 0.28

---@class beat.MotionService: beat.Service
---@field settings beat.SettingsService
---@field clock beat.Motion
---@field ease table<string, fun(t: number): number> # The curves a view passes to `progress`
---@field pageSlide { start: number, direction: number? }?
local Motion = {}
Motion.__index = Motion
Motion.needs = { "settings" }
Motion.handles = { "reduceMotion" }

---@param deps { settings: beat.SettingsService }
---@return beat.MotionService
function Motion.new(deps)
	local motionClock = clock.new(deps.settings.values.reduceMotion)
	motionClock:set("nowPlaying", 0)
	return setmetatable({
		settings = deps.settings,
		clock = motionClock,
		ease = clock.ease,
		pageSlide = nil,
	}, Motion)
end

--- A one-shot progress for something a view computes itself, such as a toast fading in.
---@param start number
---@param duration number
---@param now number
---@param easing fun(t: number): number?
---@return number
function Motion:progress(start, duration, now, easing)
	return clock.progress(start, duration, now, easing)
end

--- A new page arriving from `direction` (-1 back, 1 forward). A repeat click on the page already
--- showing must still restart a slide, so the caller wakes the ticker for its first frame.
---@param direction number
---@param at number? # When the slide started, for a test that needs a slide already under way
function Motion:slide(direction, at)
	self.pageSlide = { start = at or time.now(), direction = direction }
end

--- How far the page slide has travelled, 0 to 1; nil when there is none.
---@param now number
---@return number?
function Motion:slideProgress(now)
	if self.pageSlide == nil then return nil end
	return clock.progress(self.pageSlide.start, SLIDE_TIME, now, clock.ease.outCubic)
end

-- Reducing motion takes effect at once: the clock drops to its end values for every animation
-- that was under way, so nothing is left halfway.
function Motion:update(message)
	if message.type ~= "reduceMotion" then return end
	self.settings.values.reduceMotion = message.value == true
	self.clock.reduce = self.settings.values.reduceMotion
	self.settings:changed()
end

function Motion:step(now)
	local changed = self.clock:update(now)
	if self.pageSlide ~= nil then
		if now >= self.pageSlide.start + SLIDE_TIME then self.pageSlide = nil end
		changed = true
	end
	return changed, changed or self.clock:isActive()
end

return Motion
