-- Motion values, not motion that elements own. A view is built every frame from state, so a
-- transition is a number the view reads, advanced by one ticker, and nothing is attached to an
-- element that could outlive the frame it was built in.
--
-- Private to the motion service: the clock, its curves and the one-shot progress. Views get the
-- service's `ease` and `progress` instead, so there is one ticker and one owner.
---@class beat.MotionClock
---@field new fun(reduce: boolean?): beat.Motion
---@field ease table<string, fun(t: number): number>
---@field progress fun(start: number, duration: number, now: number, easing: fun(t: number): number?): number
local motion = {}

---@param value number
local function clamp01(value)
	if value < 0 then return 0 end
	if value > 1 then return 1 end
	return value
end

motion.ease = {
	linear = |t| -> t,
	outCubic = |t| -> 1 - (1 - t) ^ 3,
	inCubic = |t| -> t * t * t,
	inOutCubic = function(t)
		if t < 0.5 then return 4 * t * t * t end
		return 1 - ((-2 * t + 2) ^ 3) / 2
	end,
	outQuint = |t| -> 1 - (1 - t) ^ 5,
	outBack = function(t)
		local c1, c3 = 1.70158, 2.70158
		return 1 + c3 * (t - 1) ^ 3 + c1 * (t - 1) ^ 2
	end,
}

---@class beat.MotionValue
---@field from number
---@field to number
---@field start number
---@field duration number
---@field easing fun(t: number): number
---@field value number

---@class beat.Motion
---@field values table<string, beat.MotionValue>
---@field now number
---@field reduce boolean
---@field active boolean
local Motion = {}
Motion.__index = Motion

---@param reduce boolean?
---@return beat.Motion
function motion.new(reduce)
	return setmetatable({ values = {}, now = 0, reduce = reduce ?? false, active = false }, Motion)
end

---@param key string
---@param value number
function Motion:set(key, value)
	self.values[key] = {
		from = value,
		to = value,
		start = self.now,
		duration = 0,
		easing = motion.ease.linear,
		value = value,
	}
end

---@param key string
---@param target number
---@param duration number
---@param easing fun(t: number): number?
function Motion:animate(key, target, duration, easing)
	local known = self.values[key]
	local from = known?.value or target
	if self.reduce or duration <= 0 then
		self:set(key, target)
		return
	end

	self.values[key] = {
		from = from,
		to = target,
		start = self.now,
		duration = duration,
		easing = easing or motion.ease.outCubic,
		value = from,
	}
	self.active = true
end

---@param key string
---@param fallback number?
---@return number
function Motion:get(key, fallback)
	local known = self.values[key]
	if known == nil then return fallback or 0 end

	if known.duration <= 0 or self.now >= known.start + known.duration then
		known.value = known.to
		return known.to
	end

	local t = clamp01((self.now - known.start) / known.duration)
	local eased = known.easing(t)
	known.value = known.from + (known.to - known.from) * eased
	return known.value
end

---@return boolean
function Motion:update(now)
	self.now = now
	local active = false

	for _, known in pairs(self.values) do
		if known.duration > 0 and now < known.start + known.duration then
			active = true
		elseif known.duration > 0 then
			known.value = known.to
		end
	end

	self.active = active
	return active
end

function Motion:isActive()
	return self.active
end

--- A one-shot progress for something the view computes itself, such as a page transition.
---@param start number
---@param duration number
---@param now number
---@param easing fun(t: number): number?
---@return number
function motion.progress(start, duration, now, easing)
	if duration <= 0 then return 1 end
	local t = clamp01((now - start) / duration)
	local value = (easing or motion.ease.outCubic)(t)
	---@cast value number
	return value
end

return motion
