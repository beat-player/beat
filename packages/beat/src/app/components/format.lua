-- How numbers become words on the screen: a track time, an album length, a counted noun. These
-- write for the person looking at the window, so they live with the components and never below
-- them -- a music module or a worker must not need a vocabulary for a screen it cannot draw.
local format = {}

---@param seconds number
---@return string
function format.clock(seconds)
	if seconds == nil or seconds <= 0 then return "--:--" end

	local whole = math.floor(seconds + 0.5)
	local minutes = math.floor(whole / 60)
	local rest = whole % 60

	if minutes >= 60 then
		local hours = math.floor(minutes / 60)
		return string.format("%d:%02d:%02d", hours, minutes % 60, rest)
	end

	return string.format("%d:%02d", minutes, rest)
end

---@param seconds number
---@return string
function format.duration(seconds)
	if seconds <= 0 then return "unknown length" end

	local minutes = math.floor(seconds / 60 + 0.5)

	if minutes < 60 then
		return string.format("%d min", math.max(1, minutes))
	end

	local hours = math.floor(minutes / 60)
	local rest = minutes % 60

	if rest == 0 then return string.format("%d hr", hours) end

	return string.format("%d hr %d min", hours, rest)
end

---@param count number
---@param singular string
---@param plural string?
function format.count(count, singular, plural)
	return string.format("%d %s", count, count == 1 and singular or (plural or singular .. "s"))
end

return format
