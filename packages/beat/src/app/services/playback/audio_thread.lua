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
-- second, and sleeps between steps -- short while the device is open, long while it is not.
local threading = require("threading")
local treble = require("treble")
local Spectrum = require("beat.app.services.playback.spectrum")
local PcmRing = require("beat.app.services.playback.pcm")
local Prefetch = require("beat.app.services.playback.prefetch")

local AudioThread = {}

-- How much decoded audio treble stages between the prefetch ring and the device. It is small on
-- purpose: an equalizer or volume change is heard after this much audio, and a seek drops it.
local STAGING_SECONDS = 0.2

-- How often the loop reports state: with this many 5 ms sleeps, about thirty snapshots a second.
-- Position and the heard frame are interpolated between them, so this is a rate the eye cannot see.
local SNAPSHOT_EVERY = 6
local WAIT_PLAYING = 5
local WAIT_IDLE = 40

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
--- reads exactly the audio this snapshot has written.
---@param state beat.AudioThread.State
---@param player treble.Player
---@param producer beat.Spectrum?
---@return beat.AudioMessage
function AudioThread.snapshot(state, player, producer)
	local tap = player --[[@as { stream: { sampleRate: number? }? }]]
	local stream = tap.stream
	local rate = stream ~= nil and stream.sampleRate or nil
	if type(rate) == "number" then state.sampleRate = rate end

	local written, floor = nil, nil
	if producer ~= nil then
		written = producer.written
		floor = producer.floor
	end

	return {
		kind = "snapshot",
		position = player:position(),
		duration = player:duration(),
		playing = player:isPlaying(),
		heard = player:playedFrames(),
		sampleRate = state.sampleRate,
		written = written,
		floor = floor,
		index = state.index,
		commandId = state.commandId
	}
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
		device = nil
	}

	---@param event beat.AudioMessage
	local function send(event)
		-- A window that is not drawing -- the phone in a pocket, the app on another workspace --
		-- must not make the queue grow without bound: an old snapshot is worth less than the next
		-- one. A track change or an error is never dropped.
		if event.kind == "snapshot" and events:count() > 64 then return end
		events:push(event)
	end

	local player = AudioThread.open(state, send, producer)

	local quiet = SNAPSHOT_EVERY
	local reapedAt = 0
	while true do
		local quit = false
		while true do
			local command = commands:pop() --[[@as beat.AudioMessage?]]
			if command == nil then break end
			if command.kind == "quit" then
				quit = true
				break
			end
			local ok, applied = pcall(AudioThread.apply, state, player, command, send, producer)
			if ok then
				player = applied --[[@as treble.Player]]
			else
				send({ kind = "error", message = tostring(applied) })
			end
			state.commandId = command.id or state.commandId
			quiet = SNAPSHOT_EVERY
		end
		if quit then break end

		local ok, err = pcall(player.update, player)
		if not ok then send({ kind = "error", message = tostring(err) }) end

		reapedAt += 1
		if reapedAt >= 30 then
			reapedAt = 0
			Prefetch.reap()
		end

		local playing = player:isPlaying()
		quiet += 1
		if quiet >= (playing and SNAPSHOT_EVERY or 1) then
			quiet = 0
			send(AudioThread.snapshot(state, player, producer))
		end

		commands:wait(playing and WAIT_PLAYING or WAIT_IDLE)
	end

	player:close()
	Prefetch.closeAll(state.sources)
	commands:close()
	events:close()
end

return AudioThread
