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

-- The buffer treble opens on the device, in milliseconds: `DEVICE_LATENCY_US` in its ALSA backend
-- (src/raw/alsa.lua) and `DEVICE_LATENCY_SECONDS` in its AAudio one (src/raw/aaudio.lua). How long
-- the loop may sleep between feeds is a fraction of this, whatever else it does.
local DEVICE_BUFFER_MS = 150

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
---@field snapshot beat.AudioMessage? # Written into and pushed, so a report allocates nothing
---@field sentPosition number? # What the last pushed snapshot said, field by field
---@field sentDuration number?
---@field sentPlaying boolean?
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
		source:prefetch(false)
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
		send({ kind = "ended", completed = true, last = nextTrack == nil and not repeats })
		state.index = ended + 1

		if repeats then
			local fresh = Prefetch.new(track --[[@as beat.AudioTrack]])
			fresh:prefetch(false)
			player:enqueue(fresh --[[@as treble.Source]])
			if sources ~= nil then sources[ended] = fresh end
			state.index = ended
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
			-- Nobody sees the meter of an app in the background. The ring is left behind, and the
			-- first feed after coming back starts a new timeline at the frame it is fed.
			if state.background then return end
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
		local sources = makeSources(state, tracks, first)
		for at = 1, #sources do player:enqueue(sources[at] --[[@as treble.Source]]) end
		if command.autoplay ~= false then
			prefetchAt(state, 1)
			prefetchAt(state, 2)
			player:play()
			if command.startAt ~= nil and command.startAt > 0 then player:seek(command.startAt) end
			send({ kind = "started", index = state.index })
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
			if at == state.index + 1 then source:prefetch(false) end
		end
	elseif kind == "play" then
		prefetchAround(state)
		player:play()
	elseif kind == "pause" then
		player:pause()
	elseif kind == "stop" then
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
			prefetchAround(state)
			send({ kind = "started", index = state.index })
		end
	elseif kind == "seek" then
		player:seek(command.seconds or 0)
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
			local position = player:position()
			player:close()
			player = AudioThread.open(state, send, producer)
			if sources ~= nil then
				for at = first, #sources do
					local source = sources[at]
					if source ~= nil then player:enqueue(source --[[@as treble.Source]]) end
				end
			end
			if wasPlaying then
				player:play()
				if position > 0 then player:seek(position) end
			end
		end
	elseif kind == "close" then
		player:close()
		Prefetch.closeAll(state.sources)
		state.sources = nil
		state.tracks = nil
		state.index = 0
	end
	return player
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
	local tap = player --[[@as { stream: { sampleRate: number? }? }]]
	local stream = tap.stream
	local rate = stream ~= nil and stream.sampleRate or nil
	if type(rate) == "number" then state.sampleRate = rate end

	local written, floor = nil, nil
	if producer ~= nil then
		written = producer.written
		floor = producer.floor
	end

	if heard == nil then heard = player:playedFrames() end

	local snapshot = state.snapshot
	if snapshot == nil then
		snapshot = { kind = "snapshot" }
		state.snapshot = snapshot
	end

	snapshot.position = player:position()
	snapshot.duration = player:duration()
	snapshot.playing = player:isPlaying()
	snapshot.heard = heard
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
	state.sentHeard = snapshot.heard
	state.sentSampleRate = snapshot.sampleRate
	state.sentWritten = snapshot.written
	state.sentFloor = snapshot.floor
	state.sentIndex = snapshot.index
	state.sentCommandId = snapshot.commandId
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
		background = false
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
	local stallFrames = -1
	local stallAt = now
	local stalled = false

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

		local ok, err = pcall(player.update, player)
		if not ok then send({ kind = "error", message = tostring(err) }) end

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

		-- A device that says it is playing but reports the same heard frame for a fifth of a second
		-- is not playing: its sink went away, or it was suspended underneath us. Say so once, then
		-- keep stepping slowly so the recovery is noticed.
		if rawPlaying then
			if heard > stallFrames then
				stallFrames = heard
				stallAt = now
				if stalled then
					stalled = false
					forced = true
				end
			elseif heard > 0 and now - stallAt >= STALL_SECONDS then
				-- A device still opening has written nothing yet; only a frozen frame counts once
				-- playback has got somewhere.
				if not stalled then
					stalled = true
					forced = true
					Log.write("warn", "the audio output stopped advancing; reporting the player as paused")
				end
			end
		else
			stalled = false
			stallFrames = -1
			stallAt = now
		end

		local playing = rawPlaying and not stalled

		-- While playing, a snapshot goes out on a clock: the position moves every step. Otherwise
		-- only news is worth a message, so a pause that lasts an hour sends nothing at all.
		local due = forced
		if not due and playing then
			due = quiet >= (state.background and HIDDEN_SNAPSHOT_MS or PLAYING_SNAPSHOT_MS)
		end
		if due or not playing then
			local snapshot = AudioThread.snapshot(state, player, producer, heard)
			snapshot.playing = playing
			if (due or differs(state, snapshot)) and send(snapshot) then
				remember(state, snapshot)
				forced = false
				quiet = 0
			end
		end

		-- How long to sleep: the display's cadence while a track plays, a slow poll while the device
		-- is stalled, and nothing at all once the pause has released the device.
		local waitMs
		if playing then
			pausedAt = now
			suspended = false
			waitMs = state.background and WAIT_BACKGROUND or WAIT_PLAYING
		elseif stalled then
			waitMs = WAIT_STALLED
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
