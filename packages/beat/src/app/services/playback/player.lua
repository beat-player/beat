-- treble, under the library's queue.
--
-- treble owns the device and the audio queue; this owns what the app means by next, previous,
-- repeat and shuffle. A manual skip reloads the treble queue at the new position, which costs a
-- short silence and keeps the two orders from drifting after a shuffle or a repeat.
local treble = require("treble")
local Queue = require("beat.app.services.playback.queue")

---@class beat.Player
---@field queue beat.Queue?
---@field player treble.Player?
---@field volume number
---@field lastVolume number
---@field isMuted boolean
---@field error string?
---@field pending string?
---@field pendingNextAt number?
---@field loaded boolean
---@field lastPosition number
---@field orderDirty boolean
---@field loadedRepeatMode "off"|"all"|"one"
---@field fadeGain number
---@field fadeStart number?
---@field fadeActive boolean
---@field fadeDuration number
---@field onSamples fun(samples: any, frames: number, channels: number)?
---@field onTrackStarted fun(track: beat.Track, position: number)?
---@field onTrackEnded fun(track: beat.Track, completed: boolean)?
---@field onQueueChanged fun()?
---@field playingTrack beat.Track? # The track listeners were told has started, until told it ended
---@field equalizerBands treble.Equalizer.Band[]?
---@field startAt number? # Where the current track starts when it next plays: a restored session's place, or a seek made while nothing was loaded
local Player = {}
Player.__index = Player

---@return beat.Player
function Player.new()
	---@type beat.Player
	return setmetatable({
		queue = nil,
		player = nil,
		volume = 1,
		lastVolume = 1,
		isMuted = false,
		error = nil,
		pending = nil,
		pendingNextAt = nil,
		loaded = false,
		lastPosition = 0,
		orderDirty = false,
		loadedRepeatMode = "off",
		fadeGain = 1,
		fadeStart = nil,
		fadeActive = false,
		fadeDuration = 0.12,
		equalizerBands = nil,
		playingTrack = nil,
	}, Player)
end

---@param value number
local function clampVolume(value)
	return math.max(0, math.min(1, value))
end

---@param self beat.Player
local function applyVolume(self)
	if self.player == nil then return end
	self.player:setVolume(self.isMuted and 0 or self.volume * self.fadeGain)
end

--- A manual start fades in over 120 ms; an automatic track change keeps the target volume.
---@param self beat.Player
local function beginFade(self)
	self.fadeGain = 0
	self.fadeStart = nil
	self.fadeActive = true
end

-- A track that starts or stops being the one playing is announced once, here, rather than by
-- looking at the queue every tick: a repeat-one restart stays on the same track, and a skip moves
-- the queue before the new track has had a chance to start.
---@param self beat.Player
---@param track beat.Track
---@param position number
local function beginTrack(self, track, position)
	self.playingTrack = track
	if self.onTrackStarted ~= nil then self.onTrackStarted(track, position) end
end

---@param self beat.Player
---@param completed boolean # Whether the track played to its end rather than being cut short
local function endTrack(self, completed)
	local track = self.playingTrack
	if track == nil then return end
	self.playingTrack = nil
	if self.onTrackEnded ~= nil then self.onTrackEnded(track, completed) end
end

---@param self beat.Player
local function queueChanged(self)
	if self.onQueueChanged ~= nil then self.onQueueChanged() end
end

---@param self beat.Player
local function ensurePlayer(self)
	if self.player == nil then
		self.player = treble.Player.new({ stagingSeconds = 0.2})
		self.player.onTrackEnd = function()
			self.pending = "ended"
		end
		self.player.onError = function(err)
			self.error = err
			self.pending = "error"
		end
		self.player.onSamples = function(samples, frames, channels)
			if self.onSamples ~= nil then self.onSamples(samples, frames, channels) end
		end
		if self.equalizerBands ~= nil then self.player:setEqualizer(self.equalizerBands) end
	end
	return self.player
end

--- Starts the queue at its current position.
---@param self beat.Player
---@param isPlaying boolean?
---@param fade boolean?
function Player:reload(isPlaying, fade)
	local player = ensurePlayer(self)
	player:close()
	self.loaded = false
	self.lastPosition = 0
	local startAt = self.startAt
	self.startAt = nil

	local queue = self.queue
	local track = queue and queue:current()
	-- Whatever was playing stops being the one playing: a skip has already moved the queue to the
	-- next track, and a new queue means the old track is gone. A repeat or an automatic advance
	-- ended it before asking for this reload, so there is nothing left to announce.
	endTrack(self, false)
	if queue == nil or track == nil then
		self.loaded = false
		return
	end

	-- Repeat-one is the one order treble cannot express: it must have no track after this one, or
	-- it will move on before the app can ask for the same track again.
	if queue.repeatMode == "one" then
		player:enqueue(track.path)
	else
		for at = queue.position, #queue.order do
			local nextTrack = queue.tracks[queue.order[at]]
			if nextTrack ~= nil then player:enqueue(nextTrack.path) end
		end
	end

	self.loaded = true
	self.orderDirty = false
	self.loadedRepeatMode = queue.repeatMode
	if fade ~= false then
		beginFade(self)
	else
		self.fadeGain = 1
		self.fadeActive = false
	end
	applyVolume(self)

	if isPlaying ~= false then
		player:play()
		-- A queue put back by a restored session starts where it was left, not at the top.
		beginTrack(self, track, startAt or 0)
	end
end

---@param queue beat.Queue
---@param isPlaying boolean?
function Player:load(queue, isPlaying)
	self.queue = queue
	self.pendingNextAt = nil
	queueChanged(self)
	self:reload(isPlaying)
end

---@param tracks beat.Track[]
---@param index number?
---@param opts { repeatMode: string?, shuffle: boolean?, source: string? }?
function Player:playTracks(tracks, index, opts)
	if #tracks == 0 then return end
	self:load(Queue.new(tracks, index, opts))
end

--- Puts tracks after the current one. The current track is left alone: the queue is reordered
--- at its end, because cutting into the audio already staged for the next track is what made this
--- action stutter.
---@param tracks beat.Track[]
function Player:playNext(tracks)
	if #tracks == 0 then return end
	if self.queue == nil or self.queue:current() == nil then
		self:playTracks(tracks, 1, { source = "queue"})
		return
	end

	self.queue:add(tracks, true)
	self.pendingNextAt = self.pendingNextAt or (self.queue.position + 1)
	queueChanged(self)
end

--- Adds tracks after everything already queued. With no current track they wait, paused, as
--- the queue instead of starting playback.
---@param tracks beat.Track[]
function Player:addToQueue(tracks)
	if #tracks == 0 then return end
	if self.queue == nil or self.queue:current() == nil then
		self:load(Queue.new(tracks, 1, { source = "queue"}), false)
		return
	end

	self.queue:add(tracks, false)
	if self.player ~= nil and self.queue.repeatMode ~= "one" then
		for _, track in ipairs(tracks) do
			self.player:enqueue(track.path)
		end
	end
	queueChanged(self)
end

---@param album beat.Album
---@param trackId number?
function Player:playAlbum(album, trackId)
	local index = 1
	if trackId ~= nil then
		for at, track in ipairs(album.tracks) do
			if track.id == trackId then
				index = at
				break
			end
		end
	end

	self:playTracks(album.tracks, index, { source = "album"})
end

---@param artist beat.Artist
---@param trackId number?
function Player:playArtist(artist, trackId)
	local tracks = artist.tracks
	local index = 1
	if trackId ~= nil then
		for at, track in ipairs(tracks) do
			if track.id == trackId then
				index = at
				break
			end
		end
	end

	self:playTracks(tracks, index, { source = "artist"})
end

---@param track beat.Track
---@param tracks beat.Track[]?
---@param index number?
function Player:playTrack(track, tracks, index)
	if tracks == nil then tracks = { track} end
	if index == nil then
		for at, candidate in ipairs(tracks) do
			if candidate.id == track.id then
				index = at
				break
			end
		end
	end

	self:playTracks(tracks, index or 1, { source = "track"})
end

function Player:play()
	if self.queue == nil or self.queue:current() == nil then return end
	local player = ensurePlayer(self)
	if not self.loaded then
		local startAt = self.startAt
		self:reload(true)
		if startAt ~= nil then self:seek(startAt) end
	elseif not player:isPlaying() then
		beginFade(self)
		applyVolume(self)
		player:play()
	end
end

--- A saved queue put back, paused at a place in its track. Nothing is staged and no device is
--- opened until it is played.
---@param queue beat.Queue
---@param seconds number
function Player:restore(queue, seconds)
	self.queue = queue
	self.pendingNextAt = nil
	self.loaded = false
	self.startAt = seconds
end

function Player:stop()
	if self.player ~= nil then self.player:stop() end
	endTrack(self, false)
	self.loaded = false
	self.lastPosition = 0
	self.pendingNextAt = nil
	self.fadeGain = 1
	self.fadeActive = false
	self.startAt = nil
end

function Player:pause()
	if self:isPlaying() then self.player:pause() end
end

function Player:toggle()
	if self:isPlaying() then self:pause() else self:play() end
end

---@param direction "next"|"previous"
function Player:skip(direction)
	local queue = self.queue
	if queue == nil then return end
	self.pendingNextAt = nil

	local track
	if direction == "next" then
		track = queue:next()
	else
		track = queue:previous()
	end

	if track == nil then
		if self.player ~= nil then self.player:stop() end
		endTrack(self, false)
		self.loaded = false
		return
	end

	self:reload(true)
end

--- Jumps to a track already in the queue, keeping shuffle and repeat.
---@param trackId number
function Player:jump(trackId)
	local queue = self.queue
	if queue == nil then return end
	self.pendingNextAt = nil
	if queue:jump(trackId) == nil then return end
	self:reload(true)
end

function Player:next()
	self:skip("next")
end

function Player:previous()
	if self:position() > 3 then
		self:seek(0)
		return
	end
	self:skip("previous")
end

---@param seconds number
function Player:seek(seconds)
	-- With nothing loaded there is nothing to move; the place is kept for when the track starts.
	if not self.loaded then
		if self.queue ~= nil then self.startAt = math.max(0, seconds) end
		return
	end
	if self.player == nil then return end
	self.player:seek(seconds)
	self.lastPosition = self.player:position()
end

--- The bands are kept here as well as in treble: a reload closes treble's player and opens it
--- again for the next track, and the equalizer has to survive that hand-over.
---@param bands treble.Equalizer.Band[]?
function Player:setEqualizer(bands)
	if bands == nil or #bands == 0 then
		self.equalizerBands = nil
	else
		local copy = {}
		for at = 1, #bands do
			copy[at] = {
				frequency = bands[at].frequency,
				gain = bands[at].gain,
				q = bands[at].q,
			}
		end
		self.equalizerBands = copy
	end
	if self.player ~= nil and self.player.setEqualizer ~= nil then
		self.player:setEqualizer(self.equalizerBands)
	end
end

---@param value number
function Player:setVolume(value)
	self.volume = clampVolume(value)
	if not self.isMuted then self.lastVolume = self.volume end
	applyVolume(self)
end

function Player:toggleMute()
	self.isMuted = not self.isMuted
	applyVolume(self)
	return self.isMuted
end

--- A setting change only reorders the app's queue. Treble has already staged a next track and
--- is left alone; the order is handed over at the track boundary, where a reload is expected.
---@param value boolean
function Player:setShuffle(value)
	if self.queue == nil then return end
	if self.queue.shuffle == value then return end
	self.queue:toggleShuffle()
	self.orderDirty = true
	queueChanged(self)
end

function Player:cycleRepeat()
	if self.queue ~= nil then self.queue:cycleRepeat() end
end

---@return beat.Track?
function Player:current()
	return self.queue and self.queue:current() or nil
end

---@return number
function Player:position()
	if self.startAt ~= nil then return self.startAt end
	if self.player == nil then return 0 end
	return self.player:position()
end

---@return number
function Player:duration()
	local track = self:current()
	if track ~= nil and track.duration > 0 then return track.duration end
	if self.player == nil then return 0 end
	return self.player:duration()
end

---@return boolean
function Player:isPlaying()
	return self.player ~= nil and self.player:isPlaying()
end

---@return string?
function Player:takeError()
	local err = self.error
	self.error = nil
	return err
end

--- One step of the audio device. Returns whether a frame is worth drawing.
---@param now number?
---@return boolean
function Player:update(now)
	if self.player == nil then return false end

	self.player:update()

	if self.fadeActive then
		if now == nil then
			self.fadeGain = 1
			self.fadeActive = false
		else
			if self.fadeStart == nil then self.fadeStart = now end
			local t = math.max(0, math.min(1, (now - self.fadeStart) / self.fadeDuration))
			if t >= 1 then
				self.fadeGain = 1
				self.fadeActive = false
			else
				self.fadeGain = 1 - (1 - t) ^ 3
			end
		end
		applyVolume(self)
	end

	local pending = self.pending
	self.pending = nil

	if pending == "error" then
		return true
	end

	if pending == "ended" then
		local queue = self.queue
		if queue == nil then
			endTrack(self, true)
			return true
		end

		if self.pendingNextAt ~= nil then
			endTrack(self, true)
			queue.position = math.max(1, math.min(self.pendingNextAt, #queue.order))
			self.pendingNextAt = nil
			self:reload(true, false)
			return true
		end

		local action = queue:onEnded()
		-- Shuffle and repeat-one cannot be applied to treble's already staged queue without
		-- cutting the current track. The setting was allowed to change at once; the reload that
		-- makes the staged queue agree with it happens here, at the boundary.
		local stale = self.orderDirty
		or (self.loadedRepeatMode == "one") ~= (queue.repeatMode == "one")
		-- The track played to its end, whichever comes next: the same one for repeat-one, the
		-- staged one treble already started, or nothing at all at the end of the queue.
		endTrack(self, true)
		if stale then
			if action == "stop" then
				if self.player ~= nil then self.player:stop() end
				self.loaded = false
				self.fadeGain = 1
				self.fadeActive = false
			else
				self:reload(true, false)
			end
		elseif action == "again" then
			self:reload(true, false)
		elseif action == "next" then
			-- treble already started the next item it had queued.
			self.fadeGain = 1
			self.fadeActive = false
			applyVolume(self)
			beginTrack(self, queue:current() --[[@as beat.Track]], 0)
		else
			self.loaded = false
			self.fadeGain = 1
			self.fadeActive = false
		end
		return true
	end

	if not self:isPlaying() then return false end

	local position = self.player:position()
	local changed = math.abs(position - self.lastPosition) >= 0.05
	self.lastPosition = position

	return changed or true
end

function Player:close()
	endTrack(self, false)
	if self.queue ~= nil then queueChanged(self) end
	if self.player ~= nil then
		self.player:close()
		self.player = nil
	end
	self.queue = nil
	self.loaded = false
	self.fadeGain = 1
	self.fadeStart = nil
	self.fadeActive = false
	self.startAt = nil
end

return Player
