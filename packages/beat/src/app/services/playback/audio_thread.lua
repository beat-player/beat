-- The audio thread: a treble.Player of its own, and the loop that keeps it fed.
--
-- Decoding a file is the one thing in playback that waits on something outside the program -- a
-- disk, a network mount, a phone's storage. On the app's thread that wait is the whole window
-- freezing. So the player lives here instead: this thread owns the device, and the app's thread
-- hands it commands and reads the state it reports. What crosses is only small Lua values through
-- two channels, and PCM through a fixed ring both threads map.
--
-- This thread must not wait on a file either: a read that takes half a second would leave the
-- device empty. Every track is therefore a prefetch source with a reader thread of its own and a
-- ring of decoded PCM a few seconds long (see `prefetch.lua`), so what `player:update` does here is
-- memory work. The loop drains commands, steps treble, reports a snapshot a few dozen times a
-- second while a track plays, and sleeps between steps. While nothing plays it does not sleep at
-- all: it blocks on the command channel until the app asks for something, after releasing the
-- device it might otherwise hold for an hour.
local threading = require("threading")
local treble = require("treble")
local time = require("wonderland.time")
local Log = require("beat.log")
local Spectrum = require("beat.app.services.playback.spectrum")
local PcmRing = require("beat.app.services.playback.pcm")
local Prefetch = require("beat.app.services.playback.prefetch")

local AudioThread = {}

-- How much decoded audio treble stages between the prefetch ring and the device. It is small on
-- purpose: an equalizer or volume change is heard after this much audio, and a seek drops it. It is
-- also what keeps the device fed between two wakes: 200 ms is more than twice the longest sleep
-- below, so the staging buffer cannot empty before the loop feeds it again.
local STAGING_SECONDS = 0.2

-- How much decoded audio must be waiting in the prefetch ring before the device starts, and how
-- much before it starts again after running dry. The ring itself holds READ_AHEAD_SECONDS; a
-- second is the smallest that makes a slow drive's first read inaudible, and it is capped by the
-- ring on a source whose file is shorter than that.
local START_SECONDS = 1.0
local RESUME_SECONDS = 1.0
-- While buffering, the reader fills the ring on its own thread: look again soon enough that the
-- first second of audio is not waiting on the loop's sleep. A reader with nothing to read -- a
-- hung network mount -- would otherwise make that a fifty-wakeup-a-second wait forever: after a
-- second with no new frames the loop backs off to the slow pace, and the first frames that arrive
-- put it back.
local WAIT_BUFFERING = 20
local WAIT_BUFFERING_SLOW = 100
local BUFFER_BACKOFF_SECONDS = 1

-- The buffer treble opens on the device, in milliseconds: `DEVICE_LATENCY_US` in its ALSA backend
-- (src/raw/alsa.lua) and `DEVICE_LATENCY_SECONDS` in its AAudio one (src/raw/aaudio.lua). How long
-- the loop may sleep between feeds is a fraction of this, whatever else it does.
local DEVICE_BUFFER_MS = 150

-- What must stay decoded ahead while playing: one staging buffer plus one device buffer, so the
-- next fill cannot reach an empty ring. Falling below that pauses the device into buffering.
local LOW_SECONDS = STAGING_SECONDS + DEVICE_BUFFER_MS / 1000

-- How long the loop sleeps between steps. While the app draws, a twentieth of a second: the
-- position and the heard frame are interpolated between snapshots, and 20 ms is often enough to
-- keep the ring and the staging buffer fed. While the app shows nothing -- in the background, the
-- screen off -- nobody watches a playhead or a meter, so the loop wakes only as often as the
-- device needs feeding: half its buffer, never less than 40 ms and never more than 100.
local WAIT_PLAYING = 20
local WAIT_BACKGROUND = math.min(100, math.max(40, math.floor(DEVICE_BUFFER_MS / 2)))
-- A device that stopped advancing may start again at any moment, so a stalled player is polled.
local WAIT_STALLED = 250
-- Nothing is playing: one last timed wait, so the device is not held for an hour after a pause, and
-- then the loop blocks on the command channel until the app asks for something.
local SUSPEND_SECONDS = 5
-- While the app says it plays, the frame the device hears should keep moving. If it has not moved
-- for this long, the output is stalled -- a dead sink, a device that was taken away -- and the app
-- is told the player is paused instead of showing a playhead that never moves.
local STALL_SECONDS = 0.2

-- How often a snapshot goes out while playing: about twenty-five a second while the app draws,
-- four a second while it is hidden, as often as its own tick reads them.
local PLAYING_SNAPSHOT_MS = 40
local HIDDEN_SNAPSHOT_MS = 250

--- One command or event on its way between the app thread and the audio thread. Which fields mean
--- something is what `kind` says; a command carries the queue for a load, an event the state a
--- snapshot saw. It is one class because both sides serialize it the same way.
---@class beat.AudioTrack
---@field path string
---@field sampleRate number?
---@field channels number?
---@field frameCount number?

---@class beat.AudioMessage
---@field kind string
---@field id number?
---@field tracks beat.AudioTrack[]?
---@field track beat.AudioTrack?
---@field index number?
---@field startAt number?
---@field autoplay boolean?
---@field repeatOne boolean?
---@field seconds number?
---@field value number?
---@field bands treble.Equalizer.Band[]?
---@field device string?
---@field position number?
---@field duration number?
---@field playing boolean?
---@field buffering boolean? # The user wants playback but the device is held until data arrives
---@field buffered number? # Seconds decoded and waiting ahead of the current source
---@field completed boolean?
---@field last boolean? # Whether nothing is staged or repeated after the track that ended
---@field heard number?
---@field sampleRate number?
---@field written number?
---@field floor number?
---@field commandId number?
---@field message string?

---@class beat.AudioThread.State
---@field index number # The track being heard, as the app numbered the queue when it loaded it
---@field tracks beat.AudioTrack[]? # What was loaded, in the app's order
---@field sources beat.PrefetchSource[]? # One per track, started a little before its turn
---@field repeatOne boolean
---@field commandId number # The last command applied, so a snapshot says what it includes
---@field sampleRate number? # The last stream's rate, for counting heard frames between snapshots
---@field device string? # The output device the next player opens
---@field background boolean # The app shows nothing, so the loop wakes less
---@field wantsPlay boolean # The user asked for playback; a load of a stopped queue is false
---@field buffering boolean # The device is held paused until enough is decoded ahead
---@field starting boolean # The next start of the current track needs the full start buffer
---@field bufferHeard number? # The heard frame when the device was paused to buffer
---@field bufferPosition number? # The track position when the device was paused to buffer
---@field startPosition number? # A load or seek's place, before treble has adopted the track
---@field bufferWaitAt number? # When continuous buffering last saw new decoded frames
---@field bufferAvailable number? # The ring's frame count at that moment
---@field bufferIndex number? # The source it was counted on
---@field snapshot beat.AudioMessage? # Written into and pushed, so a report allocates nothing
---@field sentPosition number? # What the last pushed snapshot said, field by field
---@field sentDuration number?
---@field sentPlaying boolean?
---@field sentBuffering boolean?
---@field sentBuffered number?
---@field sentHeard number?
---@field sentSampleRate number?
---@field sentWritten number?
---@field sentFloor number?
---@field sentIndex number?
---@field sentCommandId number?

--- Starts the reader for a track before treble reaches it, so the ring is full when it does.
---@param state beat.AudioThread.State
---@param at number
local function prefetchAt(state, at)
	local sources = state.sources
	if sources == nil then return end
	local source = sources[at]
	if source ~= nil and not source.prefetched and not source.closed then
		source:prefetch()
	end
end

--- The current track and the one after it: enough that a track boundary never waits for a file,
--- and few enough that a long queue does not open one reader per track.
---@param state beat.AudioThread.State
local function prefetchAround(state)
	prefetchAt(state, state.index)
	prefetchAt(state, state.index + 1)
end

--- Replaces the queue's prefetch sources with fresh ones for its tracks, from the one the load
--- starts at. The list is compact: index one is the track that starts, which is what the started
--- events and the prefetch schedule count from. Nothing is started here.
---@param state beat.AudioThread.State
---@param tracks beat.AudioTrack[]
---@param first number
---@return beat.PrefetchSource[]
local function makeSources(state, tracks, first)
	local sources = {}
	local kept = {}
	for at = first, #tracks do
		kept[#kept + 1] = tracks[at]
		sources[#sources + 1] = Prefetch.new(tracks[at])
	end
	state.sources = sources
	state.tracks = kept
	return sources
end

--- The frame a place in seconds names in a source, or nil before its reader has reported a rate.
--- `Player:seek` takes seconds, but `Source:seek` takes frames: a source told the raw seconds would
--- start decoding that many frames in -- effectively from the top of the track.
---@param source beat.PrefetchSource
---@param seconds number
---@return number? frame
local function frameAt(source, seconds)
	local rate = source.sampleRate
	if rate == nil or rate <= 0 then return nil end
	return math.floor(seconds * rate)
end

--- A treble player with the callbacks this thread needs, opening the device `state.device` names.
--- The spectrum's tap is attached only when there is a ring to fill.
---@param state beat.AudioThread.State
---@param send fun(event: beat.AudioMessage)
---@param producer beat.Spectrum?
---@return treble.Player
function AudioThread.open(state, send, producer)
	local player = treble.Player.new({ stagingSeconds = STAGING_SECONDS, device = state.device })

	player.onTrackEnd = function()
		-- treble has already moved to the item staged behind this one. The source that just played
		-- out has given all it has; its ring can go.
		local ended = state.index
		local sources = state.sources
		local tracks = state.tracks
		local finished = sources ~= nil and sources[ended] or nil
		if finished ~= nil then
			finished:close()
			if sources ~= nil then sources[ended] = nil end
		end

		-- A repeat-one queue has only this track in it, so a fresh reader for the same path is what
		-- makes the loop go on.
		local track = tracks ~= nil and tracks[ended] or nil
		local repeats = state.repeatOne and track ~= nil
		local nextTrack = tracks ~= nil and tracks[ended + 1] or nil
		-- `last` says the device has stopped for good: nothing is staged and nothing repeats, so
		-- the app must not read the pause button from a snapshot that predates this end.
		local last = nextTrack == nil and not repeats
		send({ kind = "ended", completed = true, last = last })
		state.index = ended + 1

		if repeats then
			local fresh = Prefetch.new(track --[[@as beat.AudioTrack]])
			fresh:prefetch()
			player:enqueue(fresh --[[@as treble.Source]])
			if sources ~= nil then sources[ended] = fresh end
			state.index = ended
		end

		if last then
			-- Nothing is coming: stop asking the device for audio, so the loop can let it go
			-- after a pause rather than polling a queue that ended.
			state.wantsPlay = false
			state.buffering = false
			state.starting = false
			state.startPosition = nil
			state.bufferHeard = nil
			state.bufferPosition = nil
		else
			-- A new track starts with the start threshold, not the mid-track one; the gate holds
			-- the device if this one has not decoded enough yet.
			state.starting = state.wantsPlay == true
			state.startPosition = nil
			state.bufferHeard = nil
			state.bufferPosition = nil
		end

		-- Only a track that exists is announced as started; at the end of the queue there is none.
		if repeats or nextTrack ~= nil then
			send({ kind = "started", index = state.index })
		end
		prefetchAround(state)
		-- The next track is already what the device is hearing; report it at once so the bar does
		-- not show the old track's place for a frame or two.
		send(AudioThread.snapshot(state, player, producer))
	end
	player.onError = function(err)
		send({ kind = "error", message = tostring(err) })
	end
	if producer ~= nil then
		local timeline = player --[[@as { framesWritten: number, stagedFrames: number }]]
		---@param samples ffi.cdata*
		---@param frames number
		---@param channels number
		local function onSamples(samples, frames, channels)
			-- Nothing is fed while the device is held for data: the meter must not show audio the
			-- user has not heard yet, and the ring is cleared on a load.
			if state.background or state.buffering then return end
			producer:feed(samples, frames, channels, timeline.framesWritten + timeline.stagedFrames)
		end
		player.onSamples = onSamples
	end

	return player
end

--- Applies one command to the treble player. Kept apart from the loop so the protocol can be
--- tested with a stand-in player: a fake only has to answer the methods treble does. Answers the
--- player to use next, which a device change replaces.
---@param state beat.AudioThread.State
---@param player treble.Player
---@param command beat.AudioMessage
---@param send fun(event: beat.AudioMessage)
---@param producer beat.Spectrum?
---@return treble.Player
function AudioThread.apply(state, player, command, send, producer)
	local kind = command.kind

	if kind == "load" then
		player:close()
		Prefetch.closeAll(state.sources)
		local tracks = command.tracks or {}
		local first = math.max(1, command.index or 1)
		state.index = 1
		state.repeatOne = command.repeatOne == true
		-- The place the queue starts at, until treble has adopted the first source: the app shows
		-- it instead of nought while the track is being opened.
		state.startPosition = command.startAt ~= nil and command.startAt > 0 and command.startAt or nil
		local sources = makeSources(state, tracks, first)
		if #sources == 0 then state.startPosition = nil end
		for at = 1, #sources do player:enqueue(sources[at] --[[@as treble.Source]]) end
		-- The load starts a new device timeline: the meter drops what it showed and the ring the
		-- app reads from starts again at frame nought.
		if producer ~= nil then producer:clear() end
		if command.autoplay ~= false and #sources > 0 then
			-- The reader starts where the queue starts, not at the top: treble seeks the source to
			-- the start place when it adopts it, and with the ring already there that seek leaves
			-- the prefetched audio alone.
			if command.startAt ~= nil and command.startAt > 0 then
				local frame = frameAt(sources[1], command.startAt)
				if frame ~= nil then
					sources[1].heldFrame = frame
					sources[1]:seek(frame)
				end
			end
			prefetchAt(state, 1)
			prefetchAt(state, 2)
			-- Not played here: the gate starts the device once the reader has reported the format
			-- and decoded enough, so a slow file is silent rather than choppy.
			state.wantsPlay = true
			state.buffering = true
			state.starting = false
			state.bufferHeard = nil
			state.bufferPosition = nil
			if command.startAt ~= nil and command.startAt > 0 then player:seek(command.startAt) end
			send({ kind = "started", index = state.index })
		else
			state.wantsPlay = false
			state.buffering = false
			state.starting = false
			state.bufferHeard = nil
			state.bufferPosition = nil
		end
	elseif kind == "enqueue" then
		local track = command.track
		if track ~= nil then
			local sources = state.sources
			if sources == nil then
				sources = {}
				state.sources = sources
				state.tracks = {}
			end
			local source = Prefetch.new(track)
			local at = #sources + 1
			sources[at] = source
			local tracks = state.tracks
			if tracks ~= nil then tracks[#tracks + 1] = track end
			player:enqueue(source --[[@as treble.Source]])
			if at == state.index + 1 then source:prefetch() end
		end
	elseif kind == "play" then
		-- The gate opens the device: with enough decoded ahead it happens in this same step, and
		-- with less the snapshot says the track is buffering instead of playing. A queue with
		-- nothing left has nothing to ask for.
		local sources = state.sources
		local source = sources ~= nil and sources[state.index] or nil
		if source ~= nil then
			-- A load or seek held before treble adopted the track: start the reader at that place
			-- so the adoption's own seek lands on the head and keeps the prefetched ring.
			local startAt = state.startPosition
			if startAt ~= nil and startAt > 0 then
				local frame = frameAt(source, startAt)
				if frame ~= nil then
					-- treble has not adopted the track yet, so its adoption will rewind this source
					-- before applying the held seek: keep the prefetched ring where it already is.
					if player --[[@as { playing: table? }]].playing == nil then source.heldFrame = frame end
					source:seek(frame)
				end
			end
			prefetchAround(state)
			state.wantsPlay = true
			state.buffering = true
			state.starting = false
			state.bufferHeard = nil
			state.bufferPosition = nil
		end
	elseif kind == "pause" then
		state.wantsPlay = false
		state.buffering = false
		state.starting = false
		state.bufferHeard = nil
		state.bufferPosition = nil
		player:pause()
	elseif kind == "stop" then
		state.wantsPlay = false
		state.buffering = false
		state.starting = false
		state.startPosition = nil
		state.bufferHeard = nil
		state.bufferPosition = nil
		player:stop()
	elseif kind == "next" then
		local previous = state.index
		if player:next() then
			local sources = state.sources
			local old = sources ~= nil and sources[previous] or nil
			if old ~= nil then
				old:close()
				sources[previous] = nil
			end
			state.index = previous + 1
			-- The new track starts from its beginning in the ring: it needs the start buffer, and
			-- the paused position recorded for the old one no longer means anything.
			state.starting = state.wantsPlay == true
			state.startPosition = nil
			state.bufferHeard = nil
			state.bufferPosition = nil
			prefetchAround(state)
			send({ kind = "started", index = state.index })
		end
	elseif kind == "seek" then
		local seconds = command.seconds or 0
		local accepted = player:seek(seconds)
		-- The new place is what the snapshots report while the device refills, before treble has
		-- adopted the track and after: a buffering snapshot that kept the old start place -- or
		-- nought -- would make the bar jump back before it moves on. A seek treble refused has no
		-- place of its own to report.
		state.startPosition = accepted ~= false and seconds or nil
		local tap = player --[[@as { playing: table? }]]
		if tap.playing == nil then
			-- treble holds the seek until it adopts the track; move the source head too, so its
			-- reader fills from the new place and the adoption's seek finds it already there.
			local sources = state.sources
			local source = sources ~= nil and sources[state.index] or nil
			if source ~= nil then
				local frame = frameAt(source, seconds)
				if frame ~= nil then
					source.heldFrame = frame
					source:seek(frame)
				end
			end
		end
		state.bufferHeard = nil
		state.bufferPosition = nil
		if state.wantsPlay then state.starting = true end
	elseif kind == "volume" then
		player:setVolume(command.value or 0)
	elseif kind == "equalizer" then
		player:setEqualizer(command.bands)
	elseif kind == "background" then
		state.background = command.value == true
	elseif kind == "device" then
		-- treble takes a device when its player is made, so this is a new player with the queue and
		-- place it had: the app sees the same track continue on the other output.
		if command.device ~= state.device then
			state.device = command.device
			local sources = state.sources
			local first = state.index
			local wasPlaying = player:isPlaying()
			local tap = player --[[@as { playing: table? }]]
			local position
			if state.buffering then
				position = state.bufferPosition or state.startPosition or 0
			elseif tap.playing == nil then
				position = state.startPosition or 0
			else
				position = player:position()
			end
			player:close()
			player = AudioThread.open(state, send, producer)
			if sources ~= nil then
				for at = first, #sources do
					local source = sources[at]
					if source ~= nil then player:enqueue(source --[[@as treble.Source]]) end
				end
			end
			if wasPlaying then player:play() end
			-- The new player keeps the queue and the place: a held start is a pending seek, and
			-- the gate opens the device from there. Moving the source head to the same frame keeps
			-- the adoption's seek from resetting a ring the gate is about to wait on.
			if position > 0 then
				local lead = sources ~= nil and sources[first] or nil
				if lead ~= nil and lead.sampleRate > 0 then
					local frame = math.floor(position * lead.sampleRate)
					lead.heldFrame = frame
					lead:seek(frame)
				end
				player:seek(position)
			end
			state.startPosition = position > 0 and position or nil
		end
	elseif kind == "close" then
		player:close()
		Prefetch.closeAll(state.sources)
		state.sources = nil
		state.tracks = nil
		state.index = 0
		state.wantsPlay = false
		state.buffering = false
		state.starting = false
		state.startPosition = nil
		state.bufferHeard = nil
		state.bufferPosition = nil
	end
	return player
end

--- The prefetch source treble's next `update` would read from, or nil when that step would not read
--- at all. treble fills the staging buffer for the track it decodes, or for the one playing when
--- nothing is queued behind it; a spent decoder is swapped for the next queued track during the
--- same update, so that is the source to gate. A read may only happen when this source has enough
--- decoded ahead: its ring is memory, and reaching into an empty one is what used to freeze the
--- thread inside a file read.
---@param player treble.Player
---@return beat.PrefetchSource?
function AudioThread.feedSource(player)
	local tap = player --[[@as { playing: treble.Player.Track?, decoding: treble.Player.Track?, queue: table[]? }]]
	local track = tap.decoding or tap.playing
	local source
	if track == nil or track.isDone then
		local queue = tap.queue
		local queued = queue ~= nil and queue[1] or nil
		local item = queued ~= nil and queued.item or nil
		if item == nil then
			-- Nothing is adopted, and a spent track is not read again.
			return nil
		end
		if type(item) ~= "table" then return nil end
		source = item
	else
		source = track.source
	end
	if source == nil or type(source.available) ~= "function" then return nil end
	return source --[[@as beat.PrefetchSource]]
end

--- Holds the device paused while the reader catches up, and opens it again when it has. Called
--- before every step: with too little decoded ahead -- or before the reader has reported the
--- format -- treble's fill must not run, because its read would wait inside the source. The pause
--- is taken at the spot the device had reached, so nothing more is heard and the snapshot keeps
--- the playhead there while the ring fills.
---@param state beat.AudioThread.State
---@param player treble.Player
---@return boolean feed # Whether `update` may run this step
---@return boolean changed # Whether buffering began or ended
function AudioThread.gate(state, player)
	if not state.wantsPlay then
		state.starting = false
		if state.buffering then
			state.buffering = false
			state.bufferHeard = nil
			state.bufferPosition = nil
			return false, true
		end
		return false, false
	end

	local source = AudioThread.feedSource(player)
	if source == nil then
		state.starting = false
		if state.buffering then
			-- Nothing left to read: there is no data to wait for.
			state.buffering = false
			state.bufferHeard = nil
			state.bufferPosition = nil
			return true, true
		end
		return true, false
	end
	if player --[[@as { isStopped: boolean? }]].isStopped and not state.buffering then
		-- treble stopped the device under playback -- it could not open it, or the sink went away
		-- and it said so through onError. A fresh load or play sets buffering before the gate, so
		-- reaching here stopped means there is nothing left to wait for; stop polling.
		state.wantsPlay = false
		state.starting = false
		return true, false
	end
	if not source.prefetched and not source.closed then
		-- treble reached a track whose reader was not scheduled yet: a short track runs its decoder
		-- to the end and the next one is adopted while the current one still plays, which can be
		-- further ahead than the prefetch schedule around the heard index. Starting it here keeps
		-- the gate waiting for a ring that will actually fill.
		source:prefetch()
	end

	local rate = source.sampleRate
	if rate <= 0 then rate = state.sampleRate or 0 end
	local available = source:available()
	local finished = source:finished()
	local seconds
	if state.buffering then
		seconds = RESUME_SECONDS
	elseif state.starting then
		seconds = START_SECONDS
	else
		seconds = LOW_SECONDS
	end
	local threshold = seconds * rate
	local capacity = source.capacity
	if capacity > 0 and threshold > capacity then threshold = capacity end
	-- Whatever the seconds say, one fill can ask for every free frame of the staging buffer. On a
	-- track of another rate that free space can be more frames than the threshold names, so it is
	-- the bound that matters: a read the gate allows must never run the ring empty.
	local staging = player --[[@as { stagingCapacity: number?, stagedFrames: number? }]]
	local room = (staging.stagingCapacity or 0) - (staging.stagedFrames or 0)
	if room > threshold then threshold = room end
	local enough = finished or (source:ready() and available >= threshold)

	if enough then
		state.starting = false
		if state.buffering then
			state.buffering = false
			state.startPosition = nil
			state.bufferHeard = nil
			state.bufferPosition = nil
			player:play()
			return true, true
		end
		state.startPosition = nil
		return true, false
	end

	-- The device may still be running: it gets paused at the frame it had played to, and the
	-- snapshot reports that frame rather than a playhead moving on with nothing behind it.
	local changed = not state.buffering
	if state.bufferHeard == nil then
		state.bufferHeard = player:playedFrames()
		state.bufferPosition = state.startPosition or player:position()
	end
	if player:isPlaying() then player:pause() end
	state.buffering = true
	state.starting = false
	return false, changed
end

--- The source of the track the app numbers as current, whose decode-ahead the snapshot reports.
---@param state beat.AudioThread.State
---@return beat.PrefetchSource?
local function currentSource(state)
	local sources = state.sources
	if sources == nil then return nil end
	return sources[state.index]
end

--- Whether the ring has been stuck for a while. While the device is held for data, the reader is
--- the only thing that can move: a ring whose frame count has not changed for a second is a read
--- that is not coming back soon (a mounted share that has gone away, a drive that stopped), and
--- the loop can wait longer for it. The source changing or any new frame resets the clock.
---@param state beat.AudioThread.State
---@param now number
---@return boolean stalled
function AudioThread.bufferProgress(state, now)
	if not state.buffering then
		state.bufferWaitAt = nil
		state.bufferAvailable = nil
		state.bufferIndex = nil
		return false
	end

	local source = currentSource(state)
	local available = source ~= nil and source:available() or 0
	local waited = state.bufferWaitAt
	local before = state.bufferAvailable
	if waited == nil or state.bufferIndex ~= state.index or before == nil or available ~= before then
		waited = now
	end
	state.bufferWaitAt, state.bufferAvailable, state.bufferIndex = waited, available, state.index
	return now - waited >= BUFFER_BACKOFF_SECONDS
end

--- Seconds of decoded audio the current source has ready ahead, nought when unknown.
---@param state beat.AudioThread.State
---@param fallbackRate number?
---@return number seconds
local function bufferedSeconds(state, fallbackRate)
	local source = currentSource(state)
	if source == nil then return 0 end
	local rate = source.sampleRate
	if rate <= 0 then rate = fallbackRate or 0 end
	if rate <= 0 then return 0 end
	return source:available() / rate
end

--- A picture of what the device is doing, including the ring's frame count so the app's spectrum
--- reads exactly the audio this snapshot has written. The table is the state's own and is written
--- in place: a push copies it, so nothing here allocates, and `heard` is what the loop already read
--- when it checked the device for a stall.
---@param state beat.AudioThread.State
---@param player treble.Player
---@param producer beat.Spectrum?
---@param heard number? # The heard frame this step read; read again when nil
---@return beat.AudioMessage
function AudioThread.snapshot(state, player, producer, heard)
	local tap = player --[[@as { stream: { sampleRate: number? }?, playing: table? }]]
	local stream = tap.stream
	local rate = stream ~= nil and stream.sampleRate or nil
	if type(rate) == "number" then state.sampleRate = rate end

	local written, floor = nil, nil
	if producer ~= nil then
		written = producer.written
		floor = producer.floor
	end

	if heard == nil then heard = player:playedFrames() end

	local buffering = state.buffering == true
	if buffering and state.bufferHeard ~= nil then heard = state.bufferHeard end

	local snapshot = state.snapshot
	if snapshot == nil then
		snapshot = { kind = "snapshot" }
		state.snapshot = snapshot
	end

	-- While the device is held for data it is not playing and the playhead is the place it was
	-- paused at, not a wall-clock guess from a position that cannot move. Before treble has
	-- adopted the first source, a load or seek's place is the only one there is.
	local adopted = tap.playing ~= nil
	if buffering then
		snapshot.position = state.bufferPosition or state.startPosition or 0
		snapshot.playing = false
	elseif not adopted and state.startPosition ~= nil then
		snapshot.position = state.startPosition
		snapshot.playing = player:isPlaying()
	else
		snapshot.position = player:position()
		snapshot.playing = player:isPlaying()
	end
	snapshot.duration = player:duration()
	snapshot.heard = heard
	snapshot.buffering = buffering
	snapshot.buffered = bufferedSeconds(state, state.sampleRate)
	snapshot.sampleRate = state.sampleRate
	snapshot.written = written
	snapshot.floor = floor
	snapshot.index = state.index
	snapshot.commandId = state.commandId

	---@cast snapshot beat.AudioMessage
	return snapshot
end

--- Whether a snapshot says anything the last pushed one did not. Paused or stopped the loop reports
--- the same numbers on every wake, and the app has no use for a second copy of them; the comparison
--- is over plain numbers, so deciding costs nothing.
---@param state beat.AudioThread.State
---@param snapshot beat.AudioMessage
local function differs(state, snapshot)
	return snapshot.position ~= state.sentPosition
		or snapshot.duration ~= state.sentDuration
		or snapshot.playing ~= state.sentPlaying
		or snapshot.buffering ~= state.sentBuffering
		or snapshot.buffered ~= state.sentBuffered
		or snapshot.heard ~= state.sentHeard
		or snapshot.sampleRate ~= state.sentSampleRate
		or snapshot.written ~= state.sentWritten
		or snapshot.floor ~= state.sentFloor
		or snapshot.index ~= state.sentIndex
		or snapshot.commandId ~= state.sentCommandId
end

--- Keeps what was pushed, so the next wake can tell whether there is news.
---@param state beat.AudioThread.State
---@param snapshot beat.AudioMessage
local function remember(state, snapshot)
	state.sentPosition = snapshot.position
	state.sentDuration = snapshot.duration
	state.sentPlaying = snapshot.playing
	state.sentBuffering = snapshot.buffering
	state.sentBuffered = snapshot.buffered
	state.sentHeard = snapshot.heard
	state.sentSampleRate = snapshot.sampleRate
	state.sentWritten = snapshot.written
	state.sentFloor = snapshot.floor
	state.sentIndex = snapshot.index
	state.sentCommandId = snapshot.commandId
end

--- What the loop knows about whether the device is advancing: the heard frame at the last step
--- that saw it move, when that was, and whether the output is stalled now. Made once per thread.
---@class beat.AudioThread.Stall
---@field frames number
---@field at number
---@field stalled boolean

--- A device that says it is playing but reports the same heard frame for a fifth of a second is
--- not playing: its sink went away, or it was suspended underneath us. A frame that went back is
--- movement too: treble counts from zero again for a new track and from the new place after a
--- seek, and waiting for it to pass the old track's count made every track after the first a
--- stalled one. A device still opening has written nothing yet; only a frozen frame counts once
--- playback has got somewhere.
---@param stall beat.AudioThread.Stall
---@param playing boolean # What the player says
---@param heard number # The frame the device is heard at
---@param now number
---@return boolean changed # Whether the output just stalled or just recovered
function AudioThread.watchStall(stall, playing, heard, now)
	if not playing then
		stall.stalled = false
		stall.frames = -1
		stall.at = now
		return false
	end
	if heard ~= stall.frames then
		stall.frames = heard
		stall.at = now
		if stall.stalled then
			stall.stalled = false
			return true
		end
	elseif heard > 0 and now - stall.at >= STALL_SECONDS and not stall.stalled then
		stall.stalled = true
		return true
	end
	return false
end

--- Runs until a quit command. `commandAddress`, `eventAddress` and `pcmAddress` are the eight-byte
--- addresses the app thread made; the ring is the one the app's spectrum reads.
---@param commandAddress string
---@param eventAddress string
---@param pcmAddress string?
function AudioThread.run(commandAddress, eventAddress, pcmAddress)
	local commands = threading.channelFromAddress(commandAddress)
	local events = threading.channelFromAddress(eventAddress)
	---@type beat.Spectrum?
	local producer = nil
	if pcmAddress ~= nil and pcmAddress ~= "" then
		producer = Spectrum.new(PcmRing.fromAddress(pcmAddress).pointer)
	end

	---@type beat.AudioThread.State
	local state = {
		index = 0,
		tracks = nil,
		sources = nil,
		repeatOne = false,
		commandId = 0,
		sampleRate = nil,
		device = nil,
		background = false,
		wantsPlay = false,
		buffering = false,
		starting = false,
		bufferHeard = nil,
		bufferPosition = nil,
		startPosition = nil
	}

	---@param event beat.AudioMessage
	local function send(event)
		-- A window that is not drawing -- the phone in a pocket, the app on another workspace --
		-- must not make the queue grow without bound: an old snapshot is worth less than the next
		-- one. A track change or an error is never dropped.
		if event.kind == "snapshot" and events:count() > 64 then return false end
		return events:push(event)
	end

	local player = AudioThread.open(state, send, producer)

	-- Milliseconds of playing time since the last snapshot went out, and whether one is owed for a
	-- reason other than the clock: a command was applied, a stall began or ended, or the first step
	-- ran. Only numbers and flags, so a step allocates nothing.
	local quiet = 0
	local forced = true
	local reapedAt = 0
	-- The last step that found the player playing, in the clock snapshots and stalls are measured
	-- against, and whether the device has been released since the pause.
	local now = time.now()
	local pausedAt = now
	local suspended = false
	-- The heard frame last step and when it last moved, for telling a live device from a dead one.
	---@type beat.AudioThread.Stall
	local stall = { frames = -1, at = now, stalled = false }

	while true do
		local quit = false
		local applied = false
		while true do
			local command = commands:pop() --[[@as beat.AudioMessage?]]
			if command == nil then break end
			if command.kind == "quit" then
				quit = true
				break
			end
			local ok, result = pcall(AudioThread.apply, state, player, command, send, producer)
			if ok then
				player = result --[[@as treble.Player]]
			else
				send({ kind = "error", message = tostring(result) })
			end
			state.commandId = command.id or state.commandId
			applied = true
		end
		if quit then break end
		-- A command may have changed what the device does; its snapshot says which one it was.
		if applied then forced = true end

		local feed, bufferingChanged = AudioThread.gate(state, player)
		if bufferingChanged then forced = true end
		if feed then
			local ok, err = pcall(player.update, player)
			if not ok then send({ kind = "error", message = tostring(err) }) end
		end

		-- treble's adoption of a source -- and the rewind the held-frame guard skips -- happened in
		-- that step if it happened at all. From here the source answers seeks plainly again.
		local adopted = player --[[@as { playing: table? }]].playing
		if adopted ~= nil and state.sources ~= nil then
			for at = 1, #state.sources do
				local source = state.sources[at]
				if source ~= nil then source.heldFrame = nil end
			end
		end

		-- Readers that finished are joined here; a command may be the last thing a source ever did,
		-- so one that arrives reaps even in the middle of a long pause.
		reapedAt += 1
		if applied or reapedAt >= 30 then
			reapedAt = 0
			Prefetch.reap()
		end

		now = time.now()
		local rawPlaying = player:isPlaying()
		local heard = player:playedFrames()
		local bufferStalled = AudioThread.bufferProgress(state, now)

		-- A track held for data is not stalled: the device is paused while the reader fills the
		-- ring, so the watch starts over as if nothing were playing.
		if AudioThread.watchStall(stall, rawPlaying and not state.buffering, heard, now) then
			forced = true
			if stall.stalled then
				Log.write("warn", "the audio output stopped advancing; reporting the player as paused")
			end
		end
		local stalled = stall.stalled

		local playing = rawPlaying and not stalled and not state.buffering

		-- While playing, a snapshot goes out on a clock: the position moves every step. Otherwise
		-- only news is worth a message, so a pause that lasts an hour sends nothing at all. A
		-- buffering track is waiting for a reader, so its buffered depth is reported on the same
		-- slow clock.
		local active = playing or state.buffering
		local due = forced
		if not due and active then
			due = quiet >= (state.background and HIDDEN_SNAPSHOT_MS or PLAYING_SNAPSHOT_MS)
		end
		if due or not active then
			local snapshot = AudioThread.snapshot(state, player, producer, heard)
			-- The snapshot's own `playing` is what treble says; a device that has stopped
			-- advancing is reported as paused instead, and a buffering track never plays.
			snapshot.playing = playing
			if (due or differs(state, snapshot)) and send(snapshot) then
				remember(state, snapshot)
				forced = false
				quiet = 0
			end
		end

		-- How long to sleep: the display's cadence while a track plays, a short poll while a
		-- reader fills the ring, a slow poll while the device is stalled, and nothing at all once
		-- the pause has released the device.
		local waitMs
		if playing then
			pausedAt = now
			suspended = false
			waitMs = state.background and WAIT_BACKGROUND or WAIT_PLAYING
		elseif stalled then
			waitMs = WAIT_STALLED
		elseif state.buffering or state.wantsPlay then
			-- Wanted audio that is not playing yet: data is arriving on another thread, so look
			-- again soon. A ring that has not moved for a second is not arriving, and a reader
			-- stuck on a dead mount should not cost fifty wakeups a second.
			waitMs = bufferStalled and WAIT_BUFFERING_SLOW or WAIT_BUFFERING
		elseif suspended then
			waitMs = math.huge
		else
			local paused = now - pausedAt
			if paused >= SUSPEND_SECONDS then
				-- Five seconds with nothing playing: the decoder and the queue stay, the device
				-- does not. A play reopens it (treble remembers the format and the place).
				local ok, err = pcall(player.suspend, player)
				if not ok then Log.write("error", "the audio device could not be released: " .. tostring(err)) end
				suspended = true
				waitMs = math.huge
			else
				waitMs = math.ceil((SUSPEND_SECONDS - paused) * 1000)
			end
		end

		local woke = commands:wait(waitMs)
		if waitMs == math.huge then
			-- Only a closed channel wakes an untimed wait with nothing queued: the app is done.
			if not woke then break end
			quiet = 0
		else
			quiet += waitMs
		end
	end

	player:close()
	Prefetch.closeAll(state.sources)
	commands:close()
	events:close()
end

return AudioThread
