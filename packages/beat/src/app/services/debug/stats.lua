-- The last second of frames, as a ring the service records into and the overlay reads once in a
-- while. It is kept apart from the service because it is arithmetic rather than the app: the
-- window and the line it comes out as are what a test can check without a window or a gpu.
local Window = {}
Window.__index = Window

---@class beat.Debug.Window
---@field times number[]
---@field durations number[]
---@field first number
---@field count number
---@field capacity number
---@field span number

--- A ring of the frames in the last `span` seconds. The arrays are made once and reused, so
--- recording a frame is two stores.
---@param span number?
---@param capacity number?
---@return beat.Debug.Window
local function newWindow(span, capacity)
	span = span or 1
	capacity = capacity or 512
	local times, durations = {}, {}
	for at = 1, capacity do
		times[at], durations[at] = 0, 0
	end
	return setmetatable({
		times = times,
		durations = durations,
		first = 1,
		count = 0,
		capacity = capacity,
		span = span
	}, Window)
end

---@param self beat.Debug.Window
---@param at number # When the frame went out
---@param duration number # How long it took to build and hand over, in milliseconds
function Window:record(at, duration)
	local index
	if self.count < self.capacity then
		self.count += 1
		index = (self.first + self.count - 2) % self.capacity + 1
	else
		-- The ring is full: the frame being replaced is the oldest one.
		index = self.first
		self.first = self.first % self.capacity + 1
	end
	self.times[index], self.durations[index] = at, duration
end

--- Drops the frames that are no longer inside the span, from the oldest end. A frame exactly a
--- span back is out: at one second without a frame the screen is idle, and the idle refresh lands
--- on that boundary rather than showing a rate of one.
---@param self beat.Debug.Window
---@param now number
function Window:prune(now)
	local cutoff = now - self.span
	while self.count > 0 and self.times[self.first] <= cutoff do
		self.first = self.first % self.capacity + 1
		self.count -= 1
	end
end

--- What the window holds at `now`: how many frames, and the average and longest of them.
---@param self beat.Debug.Window
---@param now number
---@return { frames: number, average: number, max: number }
function Window:summary(now)
	self:prune(now)
	local count = self.count
	if count == 0 then return { frames = 0, average = 0, max = 0 } end

	local total, longest, index = 0, 0, self.first
	for _ = 1, count do
		local duration = self.durations[index]
		total += duration
		if duration > longest then longest = duration end
		index = index % self.capacity + 1
	end

	return { frames = count, average = total / count, max = longest }
end

--- The overlay's two lines. The rate and the frame times are the window's, and the two memory
--- numbers are what the process holds now; a machine without `/proc/self/statm` leaves the
--- resident size out rather than showing a number it does not have.
---@param summary { frames: number, average: number, max: number }
---@param heapKiB number
---@param rssKiB number?
---@return string
local function formatLine(summary, heapKiB, rssKiB)
	local first
	if summary.frames == 0 then
		first = "idle"
	else
		first = string.format("%d fps  avg %.1f ms  max %.1f ms", summary.frames, summary.average, summary.max)
	end

	local second = string.format("lua %.1f MB", heapKiB / 1024)
	if rssKiB ~= nil then second = second .. string.format("  rss %.0f MB", rssKiB / 1024) end
	return first .. "\n" .. second
end

return {
	Window = { new = newWindow },
	format = formatLine
}
