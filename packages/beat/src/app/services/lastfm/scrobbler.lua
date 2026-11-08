-- What a scrobbler needs from playback: when a track starts, how much of it was actually heard,
-- and when it is ready to be submitted. The network side is deliberately not here -- this module
-- is the state machine and its queue, so a Last.fm client can be attached without touching the
-- player again.
---@class beat.Scrobbler
---@field trackId number?
---@field played number
---@field lastPosition number
---@field queued boolean
---@field startedAt number?
---@field queue beat.Scrobble[]
local Scrobbler = {}
Scrobbler.__index = Scrobbler

local MIN_DURATION = 30
local MAX_THRESHOLD = 240
local SEEK_SLOP = 2

---@class beat.Scrobble
---@field trackId number
---@field title string
---@field artist string
---@field album string
---@field albumArtist string
---@field number number?
---@field duration number
---@field startedAt number

local function new()
	return setmetatable({
		trackId = nil,
		played = 0,
		lastPosition = 0,
		queued = false,
		queue = {},
	}, Scrobbler)
end

local function threshold(duration)
	return math.min(MAX_THRESHOLD, duration / 2)
end

---@param track beat.Track
---@param now number
function Scrobbler:start(track, now)
	self.trackId = track.id
	self.played = 0
	self.lastPosition = 0
	self.queued = false
	self.startedAt = now
end

function Scrobbler:finish()
	self.trackId = nil
	self.played = 0
	self.lastPosition = 0
	self.queued = false
	self.startedAt = nil
end

---@param track beat.Track?
---@param position number
---@param playing boolean
---@param now number
function Scrobbler:update(track, position, playing, now)
	if track == nil then
		self:finish()
		return
	end

	if self.trackId ~= track.id then
		self:finish()
		self:start(track, now)
	end

	if playing then
		local delta = position - self.lastPosition
		-- A seek is not listening: only a normal forward step counts.
		if delta > 0 and delta <= SEEK_SLOP then self.played += delta end
	end
	self.lastPosition = position

	if not self.queued and track.duration >= MIN_DURATION
	and self.played >= threshold(track.duration) then
		self.queued = true
		if #self.queue >= 512 then table.remove(self.queue, 1) end
		self.queue[#self.queue + 1] = {
			trackId = track.id,
			title = track.title,
			artist = track.artist,
			album = track.album,
			albumArtist = track.albumArtist,
			number = track.number,
			duration = track.duration,
			startedAt = self.startedAt or now,
		}
	end
end

--- The scrobbles waiting for a network client. Taking them clears the queue.
---@return beat.Scrobble[]
function Scrobbler:take()
	local queue = self.queue
	self.queue = {}
	return queue
end

local scrobbler = { new = new}
return scrobbler
