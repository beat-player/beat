-- How numbers become words on the screen: a track time, an album length, a counted noun. These
-- write for the person looking at the window, so they live with the components and never below
-- them -- a music module or a worker must not need a vocabulary for a screen it cannot draw.
local format = {}

-- The words a number already became, kept once it is known: a view asks for the same track's time
-- and the same album's length on every frame it is built, and a string built again is a string
-- the frame did not need. A duration and a count are few and repeat across the library.
--
-- A clock is keyed by the second it shows, not by the playhead: the player's position moves by a
-- fraction of a second every frame, and a table keyed by that fraction is one permanent entry and
-- one new string per frame for as long as the track plays. It is bounded as well: a session long
-- enough to fill it starts the table over rather than holding every second it ever showed.
local CLOCK_LIMIT = 512
---@type table<number, string>
local clocks = {}
local clockCount = 0
---@type table<number, string>
local durations = {}
---@type table<string, table<number, string>>
local counts = {}

---@param seconds number
---@return string
function format.clock(seconds)
	if seconds == nil or seconds <= 0 then return "--:--" end

	local whole = math.floor(seconds + 0.5)
	local known = clocks[whole]
	if known ~= nil then return known end

	local minutes = math.floor(whole / 60)
	local rest = whole % 60
	local text
	if minutes >= 60 then
		local hours = math.floor(minutes / 60)
		text = string.format("%d:%02d:%02d", hours, minutes % 60, rest)
	else
		text = string.format("%d:%02d", minutes, rest)
	end
	if clockCount >= CLOCK_LIMIT then
		clocks = {}
		clockCount = 0
	end
	clocks[whole] = text
	clockCount = clockCount + 1
	return text
end

--- How many clocks the table holds, so a test can watch it stay inside its bound.
---@return number
function format.clockCacheSize()
	return clockCount
end

---@param seconds number
---@return string
function format.duration(seconds)
	if seconds <= 0 then return "unknown length" end

	local known = durations[seconds]
	if known ~= nil then return known end

	local minutes = math.floor(seconds / 60 + 0.5)
	local text
	if minutes < 60 then
		text = string.format("%d min", math.max(1, minutes))
	else
		local hours = math.floor(minutes / 60)
		local rest = minutes % 60
		if rest == 0 then
			text = string.format("%d hr", hours)
		else
			text = string.format("%d hr %d min", hours, rest)
		end
	end
	durations[seconds] = text
	return text
end

---@param count number
---@param singular string
---@param plural string?
function format.count(count, singular, plural)
	if plural ~= nil then
		return string.format("%d %s", count, count == 1 and singular or plural)
	end
	local byCount = counts[singular]
	if byCount == nil then
		byCount = {}
		counts[singular] = byCount
	end
	local known = byCount[count]
	if known ~= nil then return known end
	local text = string.format("%d %s", count, count == 1 and singular or singular .. "s")
	byCount[count] = text
	return text
end

return format
