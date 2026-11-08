-- Where every scrolling box in the app is: the page body, the queue panel, the folder list. One
-- table of offsets keyed by what is scrolling, because two pages with the same key are the same
-- place and should come back where they were left. A wheel event only names a target and the tick
-- eases towards it, so a fast wheel glides instead of jumping; a bar already under the hand is
-- taken as it is. Each key carries its own limit: a page states how far it can scroll while it is
-- built, and a page that states it again has replaced the old one, so nothing has to be reset.
local wonderland = require("wonderland")

local time = wonderland.time

---@class beat.ScrollService: beat.Service
---@field appearance beat.AppearanceService
---@field offsets table<string, number>
---@field targets table<string, number>
---@field limits table<string, number>
---@field animating boolean
---@field lastAt number # The easing clock's last tick
local Scroll = {}
Scroll.__index = Scroll
Scroll.needs = { "appearance" }
Scroll.handles = { "scroll" }

---@param deps { appearance: beat.AppearanceService }
---@return beat.ScrollService
function Scroll.new(deps)
	return setmetatable({
		appearance = deps.appearance,
		offsets = {},
		targets = {},
		limits = {},
		animating = false,
		lastAt = time.now(),
	}, Scroll)
end

--- Where a box is scrolled to, 0 for one never moved.
---@param key string
---@return number
function Scroll:offset(key)
	return self.offsets[key] or 0
end

--- The furthest a box can scroll, where it said; nil for one that never did.
---@param key string
---@return number?
function Scroll:limit(key)
	return self.limits[key]
end

-- A page states this while it builds, because only then does it know how tall its content is.
---@param key string
---@param max number
function Scroll:setLimit(key, max)
	self.limits[key] = max
end

--- Back to the top, with no target following it: what a box that has just opened or emptied does.
---@param key string
function Scroll:reset(key)
	self.offsets[key] = 0
	self.targets[key] = nil
end

---@param message beat.Message
function Scroll:update(message)
	local key = message.key
	-- A box that scrolls by itself names itself; anything else is the page, and the shell names it
	-- so this service never has to know where the app is.
	if type(key) ~= "string" then error("a scroll message must name its key", 2) end

	local offset = self.offsets[key] or 0
	local limit = tonumber(message.max) or self.limits[key]
	---@param value number
	local function clampScroll(value)
		value = math.max(0, value)
		return limit ~= nil and math.min(value, limit) or value
	end

	local to = tonumber(message.to)
	if to ~= nil then
		-- A bar dragged is already where the pointer put it: chasing it would make the thumb lag
		-- the hand moving it.
		offset = clampScroll(to)
		self.offsets[key] = offset
		self.targets[key] = offset
		self.animating = false
	else
		self.offsets[key] = offset
		self.targets[key] = clampScroll(
		(self.targets[key] or offset) + (tonumber(message.by) or 0) * self.appearance.theme:px(60))
		self.animating = true
		-- Start the easing clock now, then let the next frame ease away from here instead of the
		-- frame after the next idle interval.
		self.lastAt = time.now()
	end
end

function Scroll:step(now)
	local dt = math.max(0, math.min(0.1, now - self.lastAt))
	self.lastAt = now
	if not self.animating then return false, false end

	local moving = false
	for key, target in pairs(self.targets) do
		local offset = self.offsets[key] or 0
		local delta = target - offset
		if math.abs(delta) > 0.25 then
			self.offsets[key] = offset + delta * math.min(1, 18 * dt)
			moving = true
		else
			self.offsets[key] = target
		end
	end
	self.animating = moving
	return true, moving
end

--- The albums or rows a list draws: the first and last of what the viewport shows, and where the
--- first of them is placed. Nothing about it depends on where the list is scrolled from beyond the
--- offset, so it is a plain function of the numbers rather than a method.
---@param count number
---@param perRow number
---@param rowHeight number
---@param offset number
---@param viewport number
---@return number first
---@return number last
---@return number top
function Scroll.slices(count, perRow, rowHeight, offset, viewport)
	if count == 0 then return 1, 0, 0 end
	perRow = math.max(1, perRow)
	rowHeight = math.max(1, rowHeight)

	local rows = math.ceil(count / perRow)
	local visible = math.ceil(viewport / rowHeight) + 2
	local firstRow = math.min(rows, math.max(1, math.floor(offset / rowHeight) + 1))
	local lastRow = math.min(rows, firstRow + visible)
	local first = (firstRow - 1) * perRow + 1
	local last = math.min(count, lastRow * perRow)

	return first, last, (firstRow - 1) * rowHeight
end

return Scroll
