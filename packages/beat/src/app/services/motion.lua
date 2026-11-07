-- Everything that moves between two values: the `ui.motion` clock the always-moving parts read
-- (the now-playing cover's growth), and the page slide. Both are numbers a frame is drawn from, so
-- they are advanced by one ticker here rather than attached to the elements that show them.
local wonderland = require("wonderland")
local ui = require("beat-ui")

local time = wonderland.time

-- The slide's length. The shell reads its progress every frame, so every frame of it must be
-- drawn: `step` stays busy until it ends.
local SLIDE_TIME = 0.28

---@class beat.MotionService
---@field clock beat.ui.Motion
---@field pageSlide { start: number, direction: number? }?
local Motion = {}
Motion.__index = Motion
Motion.needs = { "settings" }
Motion.handles = { "reduceMotion" }

---@param deps { settings: beat.SettingsService }
---@return beat.MotionService
function Motion.new(deps)
	local clock = ui.motion.new(deps.settings.values.reduceMotion)
	clock:set("nowPlaying", 0)
	return setmetatable({
		settings = deps.settings,
		clock = clock,
		pageSlide = nil,
	}, Motion)
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
	return ui.motion.progress(self.pageSlide.start, SLIDE_TIME, now, ui.motion.ease.outCubic)
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
