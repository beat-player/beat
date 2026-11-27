-- The command and event protocol the player speaks to the audio thread, and the app thread's side
-- of it. The device is never opened here: the thread-level test loads a queue paused, which is
-- treble enqueueing paths rather than decoding them, and the rest use a stand-in player or a
-- scripted thread that only reports snapshots.
local test = require("lde-test")
local threading = require("threading")
local time = require("wonderland").time
local AudioThread = require("beat.app.services.playback.audio_thread")
local AudioClient = require("beat.app.services.playback.audio_client")

---@return table player
---@return table calls
local function fakePlayer()
	local calls = {}
	---@type { playing: boolean, volume: number, position: number, bands: any }
	local state = { playing = false, volume = 1, position = 0 }

	---@type table
	local player = {}
	function player:close()
		calls[#calls + 1] = "close"
		state.playing = false
	end
	function player:enqueue(item)
		local path = type(item) == "table" and item.path or item
		calls[#calls + 1] = "enqueue:" .. tostring(path)
	end
	function player:play()
		calls[#calls + 1] = "play"
		state.playing = true
	end
	function player:pause()
		calls[#calls + 1] = "pause"
		state.playing = false
	end
	function player:stop()
		calls[#calls + 1] = "stop"
		state.playing = false
		state.position = 0
	end
	function player:next()
		calls[#calls + 1] = "next"
		return true
	end
	function player:seek(seconds)
		calls[#calls + 1] = "seek:" .. tostring(seconds)
		state.position = seconds
	end
	function player:setVolume(value)
		calls[#calls + 1] = "volume:" .. tostring(value)
		state.volume = value
	end
	function player:setEqualizer(bands)
		calls[#calls + 1] = "equalizer"
		state.bands = bands
	end
	function player:position() return state.position end
	function player:duration() return 180 end
	function player:isPlaying() return state.playing end
	function player:playedFrames() return state.position * 44100 end
	function player:update() end

	return player, calls
end

test.it("loads a queue from the path it starts at, seeks, and says the track started", function()
	local player, calls = fakePlayer()
	local state = { index = 0, tracks = nil, sources = nil, repeatOne = false, commandId = 7, sampleRate = nil, device = nil }
	---@type beat.AudioMessage[]
	local events = {}

	AudioThread.apply(state, player, {
		kind = "load",
		tracks = {
			{ path = "tests/fixtures/tone.wav", sampleRate = 44100, channels = 1 },
			{ path = "tests/fixtures/tone.wav", sampleRate = 44100, channels = 1 },
			{ path = "tests/fixtures/tone.wav", sampleRate = 44100, channels = 1 }
		},
		index = 2,
		startAt = 12,
		autoplay = true
	}, function(event) events[#events + 1] = event end)

	test.equal(state.index, 1, "the loaded queue is numbered from the track it starts on")
	test.equal(calls[1], "close")
	test.equal(calls[2], "enqueue:tests/fixtures/tone.wav", "the queue is staged as prefetch sources")
	test.equal(calls[3], "enqueue:tests/fixtures/tone.wav")
	test.equal(calls[4], "seek:12", "the start place is held until the gate opens the device")
	test.equal(#calls, 4, "a load never starts the device before the ring has data")
	test.truthy(state.wantsPlay, "the user did ask for playback")
	test.truthy(state.buffering, "so it starts out buffering")
	test.equal(events[1].kind, "started")
	test.equal(events[1].index, 1)

	AudioThread.apply(state, player, { kind = "close" }, function() end)
	local Prefetch = require("beat.app.services.playback.prefetch")
	test.truthy(Prefetch.waitStopped(2000), "the prefetch readers stopped")
end)

test.it("applies pause, stop, seek, volume and equalizer without reloading", function()
	local player, calls = fakePlayer()
	local state = { index = 1, tracks = { { path = "/one.wav" } }, sources = nil, repeatOne = false, commandId = 0, sampleRate = nil, device = nil }

	AudioThread.apply(state, player, { kind = "pause" }, function() end)
	AudioThread.apply(state, player, { kind = "seek", seconds = 30 }, function() end)
	AudioThread.apply(state, player, { kind = "volume", value = 0.4 }, function() end)
	AudioThread.apply(state, player, { kind = "equalizer", bands = { { frequency = 60, gain = 3, q = 1 } } }, function() end)
	AudioThread.apply(state, player, { kind = "stop" }, function() end)

	test.equal(calls[1], "pause")
	test.equal(calls[2], "seek:30")
	test.equal(calls[3], "volume:0.4")
	test.equal(calls[4], "equalizer")
	test.equal(calls[5], "stop")
	test.equal(player:position(), 0, "stop rewinds")
end)

test.it("reports a seek's place while the ring refills there", function()
	local player, calls = fakePlayer()
	-- treble has adopted the track, so the seek lands on the playing source at once.
	player.playing = {}
	local state = {
		index = 1,
		tracks = { { path = "/one.wav" } },
		sources = nil,
		repeatOne = false,
		commandId = 0,
		sampleRate = 44100,
		device = nil,
		wantsPlay = true,
		buffering = false,
		starting = false
	}

	AudioThread.apply(state, player, { kind = "seek", seconds = 45 }, function() end)
	test.equal(calls[1], "seek:45")
	test.equal(state.startPosition, 45, "the seek's place is kept for the snapshots")
	test.truthy(state.starting, "and the device waits for the start buffer there")

	-- The gate has paused the device to refill the ring: the snapshot still names the target, not
	-- whatever the flushed device or an older start place would say.
	state.starting = false
	state.buffering = true
	player.position = function() return 0 end
	local snapshot = AudioThread.snapshot(state, player, nil)
	test.truthy(snapshot.buffering)
	test.equal(snapshot.position, 45)
end)

test.it("reports position, heard frames and the ring's frame counts together", function()
	local player = fakePlayer()
	player.stream = { sampleRate = 48000 }
	player:seek(90)
	local producer = { written = 5000, floor = 100 } --[[@as beat.Spectrum]]
	local state = { index = 4, tracks = nil, sources = nil, repeatOne = false, sampleRate = nil, commandId = 9, device = nil }

	local snapshot = AudioThread.snapshot(state, player, producer)

	test.equal(snapshot.kind, "snapshot")
	test.equal(snapshot.position, 90)
	test.equal(snapshot.duration, 180)
	test.equal(snapshot.playing, false)
	test.equal(snapshot.heard, 90 * 44100)
	test.equal(snapshot.sampleRate, 48000)
	test.equal(snapshot.written, 5000)
	test.equal(snapshot.floor, 100)
	test.equal(snapshot.index, 4)
	test.equal(snapshot.commandId, 9)
end)

test.it("does not take a new track's heard frame, counted from zero again, for a stall", function()
	-- The first track was heard to frame 85,000; the second starts counting at zero. A frame below
	-- the last one is the device moving on, so the second track plays rather than reading as stalled.
	---@type beat.AudioThread.Stall
	local stall = { frames = -1, at = 0, stalled = false }
	AudioThread.watchStall(stall, true, 85000, 2.0)
	AudioThread.watchStall(stall, true, 1000, 2.02)
	AudioThread.watchStall(stall, true, 4000, 2.1)
	AudioThread.watchStall(stall, true, 9000, 2.3)
	test.equal(stall.stalled, false)
end)

test.it("reports a device whose heard frame stops moving as stalled, and its recovery", function()
	---@type beat.AudioThread.Stall
	local stall = { frames = -1, at = 0, stalled = false }
	AudioThread.watchStall(stall, true, 5000, 1.0)
	test.equal(AudioThread.watchStall(stall, true, 5000, 1.1), false, "a tenth of a second is not a stall yet")
	test.equal(AudioThread.watchStall(stall, true, 5000, 1.3), true, "the stall is news once")
	test.equal(stall.stalled, true)
	test.equal(AudioThread.watchStall(stall, true, 5000, 1.5), false, "and not again while it lasts")
	test.equal(AudioThread.watchStall(stall, true, 6000, 1.6), true, "a moving frame ends it")
	test.equal(stall.stalled, false)
end)

--- A player with just the fields the buffering gate reads, recording what it is asked to do.
---@return table player
local function gatePlayer()
	local calls = {}
	---@type table
	local player = { playing = nil, decoding = nil, queue = {}, paused = false, heardFrames = 0, seconds = 0 }
	function player:play()
		calls[#calls + 1] = "play"
		self.paused = false
	end
	function player:pause()
		calls[#calls + 1] = "pause"
		self.paused = true
	end
	function player:isPlaying() return self.playing ~= nil and not self.paused end
	function player:playedFrames() return self.heardFrames end
	function player:position() return self.seconds end
	player.calls = calls
	return player
end

--- A prefetch source as the gate sees it: a ring with `frames` decoded and not yet read. Reading
--- an empty ring is an error, so a test fails loudly if the gate ever lets that happen.
---@param frames number
---@param opts { ready: boolean?, finished: boolean?, rate: number?, capacity: number? }?
---@return table source
local function gateSource(frames, opts)
	opts = opts or {}
	---@type table
	local source = {
		sampleRate = opts.rate or 44100,
		channels = 1,
		frameCount = opts.frameCount or 0,
		capacity = opts.capacity or 44100 * 2.5,
		frames = frames,
		isReady = opts.ready ~= false,
		isFinished = opts.finished == true,
		reads = 0
	}
	function source:available() return self.frames end
	function source:ready() return self.isReady end
	function source:finished() return self.isFinished end
	function source:prefetch() self.prefetched = true end
	function source:seek() return true end
	function source:read(_, frames)
		self.reads += 1
		if self.frames <= 0 then error("the gate let a read reach an empty ring") end
		local count = math.min(frames or self.frames, self.frames)
		self.frames -= count
		return count
	end
	return source
end

test.it("holds a load in buffering and never reads an empty ring", function()
	local player = gatePlayer()
	local source = gateSource(0)
	-- A fresh load: treble has staged the source but the device has not adopted it yet.
	player.queue = { { item = source } }
	local state = { index = 1, sources = { source }, wantsPlay = true, buffering = true, starting = false, sampleRate = 44100 }

	local feed = AudioThread.gate(state, player)
	test.falsy(feed, "update must not run when there is nothing to read")
	test.truthy(state.buffering, "the load stays buffering")
	test.equal(#player.calls, 0, "the device is never started")
	test.equal(source.reads, 0, "and the ring is never read")
end)

test.it("starts playback when the start buffer has arrived", function()
	local player = gatePlayer()
	local source = gateSource(44100)
	player.playing = { source = source }
	local state = { index = 1, sources = { source }, wantsPlay = true, buffering = true, starting = false, sampleRate = 44100 }

	local feed, changed = AudioThread.gate(state, player)
	test.truthy(feed)
	test.truthy(changed, "leaving buffering is news for the snapshot")
	test.falsy(state.buffering)
	test.equal(player.calls[1], "play", "enough decoded audio opens the device")
end)

test.it("re-enters buffering when the ring runs low, and wants a full second to resume", function()
	local player = gatePlayer()
	local source = gateSource(4410) -- 0.1 s, under one staging plus one device buffer
	player.playing = { source = source }
	local state = { index = 1, sources = { source }, wantsPlay = true, buffering = false, starting = false, sampleRate = 44100 }

	local feed, changed = AudioThread.gate(state, player)
	test.falsy(feed, "the device is paused instead of reading an almost empty ring")
	test.truthy(changed)
	test.truthy(state.buffering)
	test.equal(player.calls[1], "pause")
	test.equal(state.bufferHeard, 0, "the frame it had reached is kept for the snapshot")
	test.equal(state.bufferPosition, 0, "and so is the place")

	-- Half a second is more than the low threshold but under the one a resume waits for.
	source.frames = 22050
	player.paused = true
	test.falsy(AudioThread.gate(state, player), "a resume needs the start buffer, not just the low one")
	test.truthy(state.buffering)

	source.frames = 44100
	test.truthy(AudioThread.gate(state, player), "a full second starts it again")
	test.falsy(state.buffering)
	test.equal(player.calls[#player.calls], "play")
end)

test.it("plays out a source whose reader has finished", function()
	local player = gatePlayer()
	local source = gateSource(100, { finished = true })
	player.playing = { source = source }
	local state = { index = 1, sources = { source }, wantsPlay = true, buffering = true, starting = false, sampleRate = 44100 }

	local feed, changed = AudioThread.gate(state, player)
	test.truthy(feed, "a source at the end of its file has no more data to wait for")
	test.truthy(changed)
	test.falsy(state.buffering)
end)

test.it("a pause during buffering stops asking for playback", function()
	local player = gatePlayer()
	local source = gateSource(0)
	local state = { index = 1, sources = { source }, wantsPlay = true, buffering = true, starting = false, sampleRate = 44100 }

	AudioThread.apply(state, player, { kind = "pause" }, function() end)
	test.falsy(state.wantsPlay)
	test.falsy(state.buffering)
	test.equal(player.calls[1], "pause")
	test.falsy(AudioThread.gate(state, player), "the next step does not read or pause again")
	test.equal(#player.calls, 1)
end)

test.it("reports buffering, the decoded seconds ahead and the held place", function()
	local player = fakePlayer()
	local source = gateSource(88200) -- 2 s at 44.1 kHz
	local state = {
		index = 1,
		sources = { source },
		wantsPlay = true,
		buffering = true,
		bufferHeard = 4410,
		bufferPosition = 12.5,
		sampleRate = 44100
	}

	local snapshot = AudioThread.snapshot(state, player, nil)
	test.truthy(snapshot.buffering, "the snapshot says why nothing is audible")
	test.equal(snapshot.playing, false)
	test.equal(snapshot.position, 12.5, "the place is the one the device was paused at")
	test.equal(snapshot.heard, 4410, "and the heard frame does not move")
	test.equal(snapshot.buffered, 2, "the decoded seconds ahead are reported")

	-- A paused load with a start place treble has not adopted yet: nought is not the truth.
	state.buffering = false
	state.bufferPosition = nil
	state.startPosition = 30
	local held = AudioThread.snapshot(state, player, nil)
	test.falsy(held.buffering)
	test.equal(held.position, 30, "a load's start place is shown before the source is adopted")
end)

-- The gate's decision, then the real treble player's own fill: a read happens only when the gate
-- has allowed one, and the staged chunk reaches the device.
test.it("feeds a real treble player only when the gate has decoded audio", function()
	local treble = require("treble")
	local written = 0
	---@type treble.OutputStream
	local stream = {
		sampleRate = 44100,
		channels = 1,
		write = function(_, _, frames)
			written += frames
			return frames
		end,
		avail = function() return 4096 end,
		delay = function() return 0 end,
		setPaused = function() end,
		drain = function() end,
		flush = function() end,
		close = function() end
	}
	local player = treble.Player.new({
		stagingSeconds = 0.2,
		stream = function() return stream end
	})
	local source = gateSource(0)
	player:enqueue(source)
	local state = { index = 1, sources = { source }, wantsPlay = true, buffering = true, starting = false, sampleRate = 44100 }

	test.falsy(AudioThread.gate(state, player), "an empty ring may not be fed")
	test.equal(source.reads, 0, "so treble is not stepped and nothing is read")

	source.frames = 44100
	test.truthy(AudioThread.gate(state, player), "a second of audio opens the gate")
	player:update()
	test.equal(source.reads, 1, "one fill took what the staging buffer holds")
	test.truthy(written > 0, "the staged audio reached the device")
	player:close()
end)

-- The reader fills the ring on another thread. Its queries and a read must never wait for it, or the
-- audio thread would hold the device empty just as it used to inside a file read.
test.it("answers prefetch queries and reads without waiting for the reader", function()
	local ffi = require("ffi")
	local Prefetch = require("beat.app.services.playback.prefetch")
	local source = Prefetch.new({ path = "tests/fixtures/tone.wav" })

	test.equal(source:available(), 0, "nothing is decoded before the reader starts")
	test.falsy(source:ready())
	test.falsy(source:finished())

	source:prefetch()
	local out = ffi.new("int16_t[?]", 8192)

	-- A read landing while the ring is still empty answers within one loop's wait, not after the
	-- reader has decoded; the point is that it cannot park the audio thread on a file.
	local started = time.now()
	local frames = source:read(out, 8192)
	test.truthy(time.now() - started < 0.2, "an empty read did not wait for the reader")
	test.truthy(frames ~= nil)

	local waited = 0
	while not source:finished() and waited < 2000 do
		threading.sleep(5)
		waited += 5
	end
	test.truthy(source:ready(), "the reader reported the ring")
	test.truthy(source:finished(), "the short fixture reaches its end")
	test.truthy(source:available() > 0, "the decoded frames wait to be read")

	local total = frames or 0
	while true do
		local got = source:read(out, 8192)
		if got == nil or got == 0 then break end
		total += got
	end
	test.equal(total, source.frameCount, "every decoded frame comes out of the ring")

	source:close()
	test.truthy(Prefetch.waitStopped(2000), "the reader stopped")
end)

-- treble seeks every non-owned source to the top when it adopts it. That must not throw away what
-- the gate waited for: the ring is already at that head, and the first read after adoption has to
-- find audio, not the nought treble reads as the end of the track.
test.it("keeps a prefetched ring when treble seeks the source to its head", function()
	local ffi = require("ffi")
	local Prefetch = require("beat.app.services.playback.prefetch")
	local source = Prefetch.new({ path = "tests/fixtures/tone.wav" })
	source:prefetch()

	local waited = 0
	while source:available() == 0 and waited < 4000 do
		threading.sleep(5)
		waited += 5
	end
	local ready = source:available()
	test.truthy(ready > 0, "the reader decoded some audio")

	test.truthy(source:seek(0), "adoption seeks the source to its head")
	test.truthy(source:available() >= ready, "the decoded ring survives the head seek")

	local out = ffi.new("int16_t[?]", 8192)
	local got = source:read(out, 8192)
	test.truthy(got ~= nil and got > 0, "the first fill after adoption finds audio")

	source:close()
	test.truthy(Prefetch.waitStopped(2000), "the reader stopped")
end)

-- A queue restored at a place starts its reader there; the adoption seek lands on that same frame
-- and must leave the ring alone.
test.it("starts the reader at a queue's start place", function()
	local ffi = require("ffi")
	local Prefetch = require("beat.app.services.playback.prefetch")
	local source = Prefetch.new({ path = "tests/fixtures/tone.wav" })
	local startAt = 4410

	test.truthy(source:seek(startAt), "the place is set before the reader starts")
	source:prefetch()

	local waited = 0
	while source:available() == 0 and waited < 4000 do
		threading.sleep(5)
		waited += 5
	end
	test.truthy(source:available() > 0, "the reader decoded from the start place")
	test.truthy(source:seek(startAt), "adoption seeks to the same frame")

	local out = ffi.new("int16_t[?]", 8192)
	local got = source:read(out, 8192)
	test.truthy(got ~= nil and got > 0, "the first fill finds the audio decoded from there")
	test.truthy(source.frameCount - startAt >= (got or 0), "and it is the audio after the start place")

	source:close()
	test.truthy(Prefetch.waitStopped(2000), "the reader stopped")
end)

-- The gate and a real prefetch reader through a real treble player with a fake device: the ring is
-- never read empty, and the audio the reader decoded reaches the device.
test.it("plays a prefetched source through treble without an empty read", function()
	local Prefetch = require("beat.app.services.playback.prefetch")
	local treble = require("treble")
	local written = 0
	---@type treble.OutputStream
	local stream = {
		sampleRate = 44100,
		channels = 1,
		write = function(_, _, frames)
			written += frames
			return frames
		end,
		avail = function() return 4096 end,
		delay = function() return 0 end,
		setPaused = function() end,
		drain = function() end,
		flush = function() end,
		close = function() end
	}
	local player = treble.Player.new({
		stagingSeconds = 0.2,
		stream = function() return stream end
	})
	local source = Prefetch.new({ path = "tests/fixtures/tone.wav" })
	player:enqueue(source)
	---@type string[]
	local errors = {}
	player.onError = function(err) errors[#errors + 1] = err end
	local state = { index = 1, sources = { source }, wantsPlay = true, buffering = true, starting = false, sampleRate = 44100 }

	local waited = 0
	while written == 0 and waited < 3000 do
		if AudioThread.gate(state, player) then player:update() end
		threading.sleep(5)
		waited += 5
	end

	test.equal(#errors, 0, "no read failed")
	test.truthy(written > 0, "decoded audio reached the device")
	test.falsy(state.buffering, "and the gate let the device start")

	player:close()
	source:close()
	test.truthy(Prefetch.waitStopped(2000), "the reader stopped")
end)

--- A fake device that keeps every frame it is written, so a test can say which part of the track
--- was heard; and a source whose every frame is its own index, so a written value names a frame.
---@param rate number
---@return number[] samples
---@return treble.OutputStream stream
local function recordingDevice(rate)
	---@type number[]
	local samples = {}
	---@type treble.OutputStream
	local stream = {
		sampleRate = rate,
		channels = 1,
		isPaused = false,
		closed = false
	}
	function stream:write(data, frames)
		for at = 0, frames - 1 do samples[#samples + 1] = data[at] end
		return frames
	end
	function stream:avail() return 4096 end
	function stream:delay() return 0 end
	function stream:setPaused(paused) self.isPaused = paused end
	function stream:drain() end
	function stream:flush() end
	function stream:close() self.closed = true end
	return samples, stream
end

---@param rate number
---@param frames number
---@return beat.PrefetchSource source
local function rampSource(rate, frames)
	---@type table
	local source = {
		path = "/ramp",
		sampleRate = rate,
		channels = 1,
		frameCount = frames,
		capacity = rate,
		prefetched = true,
		closed = false,
		readPos = 0
	}
	function source:prefetch() return true end
	function source:ready() return true end
	function source:available() return self.frameCount - self.readPos end
	function source:finished() return false end
	function source:seek(frame)
		self.readPos = frame
		return true
	end
	function source:read(out, count)
		local got = math.min(count, self.frameCount - self.readPos)
		for at = 0, got - 1 do out[at] = (self.readPos + at) % 32768 end
		self.readPos = self.readPos + got
		return got
	end
	function source:close() self.closed = true end
	return source --[[@as beat.PrefetchSource]]
end

--- Runs the gate and treble until `done` answers true.
---@param state beat.AudioThread.State
---@param player treble.Player
---@param done fun(): boolean
---@param steps number?
---@return boolean reached
local function drive(state, player, done, steps)
	for _ = 1, steps or 2000 do
		if AudioThread.gate(state, player) then player:update() end
		if done() then return true end
		threading.sleep(2)
	end
	return done()
end

--- A playing, adopted track on a fake device, as the audio thread leaves it after a load.
---@param rate number?
---@return treble.Player player
---@return beat.PrefetchSource source
---@return number[] samples
---@return beat.AudioThread.State state
local function playingTrack(rate)
	rate = rate or 8000
	local treble = require("treble")
	local samples, stream = recordingDevice(rate)
	local player = treble.Player.new({ stagingSeconds = 0.2, stream = function() return stream end })
	local source = rampSource(rate, rate * 2)
	player:enqueue(source --[[@as treble.Source]])
	---@type beat.AudioThread.State
	local state = {
		index = 1,
		sources = { source },
		tracks = { { path = "/ramp" } },
		wantsPlay = true,
		buffering = true,
		starting = false,
		sampleRate = rate
	}
	return player, source, samples, state
end

-- The user's report: pause, drag the bar to a new place, press play. The source was seeked while
-- paused, so play must resume the reader there instead of running it back to the track's top.
test.it("plays from a seek made while paused, not from the track's top", function()
	local player, _, samples, state = playingTrack()
	test.truthy(drive(state, player, function() return #samples > 0 end, 500), "audio started")
	local heard = #samples

	AudioThread.apply(state, player, { kind = "pause" }, function() end)
	AudioThread.apply(state, player, { kind = "seek", seconds = 1 }, function() end)
	test.equal(state.startPosition, 1, "the seek's place is what the snapshots report")
	AudioThread.apply(state, player, { kind = "play" }, function() end)

	local first = heard + 1
	test.truthy(drive(state, player, function() return #samples >= first + 8 end, 500), "playback resumed")
	test.equal(samples[first], 8000, "the first frame heard is the seek target's")
	test.truthy(player:position() >= 1, "the position agrees with the audio")
	player:close()
end)

-- The same after five paused seconds: the device was released, and play opens it again. The seek
-- lands on a player with no device timeline, so the source head is the only place that matters.
test.it("plays from a seek made while paused after the device was suspended", function()
	local player, _, samples, state = playingTrack()
	test.truthy(drive(state, player, function() return #samples > 0 end, 500), "audio started")
	local heard = #samples

	AudioThread.apply(state, player, { kind = "pause" }, function() end)
	player:suspend()
	test.truthy(player.isSuspended, "the idle device was released as the thread does after five seconds")
	AudioThread.apply(state, player, { kind = "seek", seconds = 1 }, function() end)
	AudioThread.apply(state, player, { kind = "play" }, function() end)

	local first = heard + 1
	test.truthy(drive(state, player, function() return #samples >= first + 8 end, 500), "playback resumed")
	test.equal(samples[first], 8000, "the reopened device hears the seek target's frame")
	test.truthy(player:position() >= 1, "and the position agrees")
	player:close()
end)

-- A seek can arrive before treble has adopted the track. The source head is what the reader fills
-- from then, and it takes frames: a source told the app's seconds would decode from the top.
test.it("moves a buffering source to the seek's frame, not to the raw seconds", function()
	local player = gatePlayer()
	function player:seek(seconds)
		self.sought = seconds
		return true
	end
	local seeks = {}
	---@type table
	local source = {
		sampleRate = 8000,
		channels = 1,
		frameCount = 16000,
		capacity = 16000,
		prefetched = true
	}
	function source:available() return 0 end
	function source:ready() return true end
	function source:finished() return false end
	function source:prefetch() end
	function source:seek(frame)
		seeks[#seeks + 1] = frame
		return true
	end
	---@type beat.AudioThread.State
	local state = { index = 1, sources = { source }, wantsPlay = false, buffering = false, starting = false, sampleRate = 8000 }

	AudioThread.apply(state, player, { kind = "seek", seconds = 1 }, function() end)
	test.equal(state.startPosition, 1)
	test.equal(seeks[1], 8000, "the source head moves to a frame, not to one second")

	AudioThread.apply(state, player, { kind = "play" }, function() end)
	test.equal(seeks[#seeks], 8000, "play keeps the reader on the seek target")
	test.equal(#seeks, 2, "and never rewinds it")
end)

-- Seek while the load is still buffering, through a real treble player and a real prefetch reader:
-- adoption must not rewind the source to nought, or the first read finds an empty ring and treble
-- takes the nought for the end of the track.
test.it("hears a seek made while the track is still buffering from its target", function()
	local treble = require("treble")
	local Prefetch = require("beat.app.services.playback.prefetch")
	local samples, stream = recordingDevice(44100)
	local player = treble.Player.new({ stagingSeconds = 0.2, stream = function() return stream end })
	local source = Prefetch.new({ path = "tests/fixtures/tone.wav", sampleRate = 44100, channels = 1 })
	local rewinds = {}
	local seek = source.seek
	source.seek = function(self, frame)
		local before = self.readPos
		local ok = seek(self, frame)
		if self.readPos < before then rewinds[#rewinds + 1] = frame end
		return ok
	end
	source:prefetch()
	player:enqueue(source --[[@as treble.Source]])

	---@type beat.AudioMessage[]
	local events = {}
	---@type beat.AudioThread.State
	local state = {
		index = 1,
		sources = { source },
		tracks = { { path = "tests/fixtures/tone.wav" } },
		wantsPlay = true,
		buffering = true,
		starting = false,
		sampleRate = 44100
	}

	AudioThread.apply(state, player, { kind = "seek", seconds = 0.1 }, function(event) events[#events + 1] = event end)
	test.equal(source.readPos, 4410, "the reader was started at the seek target")

	local started = drive(state, player, function() return #samples > 0 end, 1000)
	test.truthy(started, "the track is heard")
	local ended = false
	for _, event in ipairs(events) do
		if event.kind == "ended" then ended = true end
	end
	test.falsy(ended, "adoption did not run the track out")
	test.equal(#rewinds, 0, "adoption did not rewind the prefetched source to nought")
	test.truthy(player:position() >= 0.1, "and the position is the seek's")

	player:close()
	source:close()
	test.truthy(Prefetch.waitStopped(2000), "the reader stopped")
end)

test.it("starts the real audio thread, loads paused and answers snapshots", function()
	local commands = threading.channel()
	local events = threading.channel()
	local commandAddress, eventAddress = commands:address(), events:address()

	local handle = threading.spawn(function()
		require("beat.app.services.playback.audio_thread").run(commandAddress, eventAddress, "")
	end)

	commands:push({ kind = "load", tracks = { { path = "/does/not/exist.wav" } }, index = 1, startAt = 0, autoplay = false, id = 1 })
	commands:push({ kind = "volume", value = 0.25, id = 2 })

	---@type beat.AudioMessage?
	local snapshot
	for _ = 1, 200 do
		if events:wait(20) then
			local event = events:pop() --[[@as beat.AudioMessage?]]
			if event ~= nil and event.kind == "snapshot" then
				snapshot = event
				break
			end
		end
	end

	test.truthy(snapshot ~= nil, "the thread reports state")
	test.equal(snapshot.playing, false)
	test.equal(snapshot.duration, 0)
	test.equal(snapshot.commandId, 2, "the snapshot includes the commands applied before it")

	commands:push({ kind = "quit", id = 3 })
	handle:join()
	commands:close()
	events:close()
end)

test.it("sends the load the client collected, with its start place", function()
	local commands = threading.channel()
	local events = threading.channel()
	local client = AudioClient.attach(commands, events, nil)

	-- The player's order for a restored session: the place first, then the reload that closes the
	-- old queue and stages the new one.
	client:setStartAt(45)
	client:close()
	client:enqueue("/a.wav")
	client:enqueue("/b.wav")
	client:play()

	test.equal(commands:pop() --[[@as beat.AudioMessage]].kind, "close")
	local command = commands:pop() --[[@as beat.AudioMessage]]
	test.equal(command.kind, "load")
	local tracks = assert(command.tracks)
	test.equal(tracks[1].path, "/a.wav")
	test.equal(tracks[2].path, "/b.wav")
	test.equal(command.startAt, 45)
	test.equal(command.index, 1)
	test.equal(command.autoplay, true)
	test.truthy(client:isPlaying())

	client:shutdown()
end)

test.it("mirrors a snapshot and moves the position on between them", function()
	local commands = threading.channel()
	local events = threading.channel()
	local client = AudioClient.attach(commands, events, nil)

	client:load({ "/a.wav" }, 10, true, false)
	local load = commands:pop() --[[@as beat.AudioMessage]]

	events:push({
		kind = "snapshot",
		position = 10,
		duration = 100,
		playing = true,
		heard = 441000,
		sampleRate = 44100,
		written = 485100,
		floor = 0,
		commandId = load.id
	})
	client:update(1.0)
	test.truthy(client:isPlaying())
	test.equal(client:position(), 10)

	-- A second of ticks with no snapshot at all: the bar keeps moving at the rate it was playing.
	local first = client:position()
	for frame = 1, 60 do client:update(1.0 + frame / 60) end
	test.truthy(client:position() > first + 0.9, "position interpolates between snapshots")
	test.truthy(client:heardFrame() > 441000 + 40000, "the heard frame does too")

	-- And a snapshot newer than the last command is the truth again.
	events:push({
		kind = "snapshot",
		position = 12,
		duration = 100,
		playing = false,
		heard = 529200,
		sampleRate = 44100,
		written = 529200,
		floor = 0,
		commandId = load.id
	})
	client:update(2.0)
	test.falsy(client:isPlaying())
	test.equal(client:position(), 12)

	client:shutdown()
end)

-- A load asks for a track nothing of which has been heard: the place is where the snapshot says
-- the device will start, never where wall-clock time has got to, and the track being replaced
-- cannot leave its length beside the new one.
test.it("holds the place and the length at nothing until the track is heard", function()
	local commands = threading.channel()
	local events = threading.channel()
	local client = AudioClient.attach(commands, events, nil)

	client:load({ "/a.wav" }, 0, true, false)
	local load = commands:pop() --[[@as beat.AudioMessage]]

	-- The first step after a load: the client's own clock starts at nought while the app's uptime
	-- does not; the place must not run on either before a snapshot reports playback.
	client:update(100000)
	test.equal(client:position(), 0, "a load does not run the playhead from the clock")
	test.equal(client:duration(), 0, "and knows no length yet")

	-- A snapshot from before the load still describes the track being replaced: neither its place
	-- nor its end time is the new track's.
	events:push({
		kind = "snapshot",
		commandId = load.id - 1,
		position = 90,
		duration = 180,
		playing = true,
		heard = 90 * 44100,
		sampleRate = 44100
	})
	client:update(100001)
	test.truthy(client:isLoading(), "the requested track is still loading")
	test.equal(client:position(), 0, "the old track's place is not this one's")
	test.equal(client:duration(), 0, "nor the old track's length")

	-- The thread has applied the load and reports it is buffering, with a little decoded ahead.
	events:push({
		kind = "snapshot",
		commandId = load.id,
		position = 0,
		duration = 120,
		playing = false,
		buffering = true,
		buffered = 0.4,
		heard = 0,
		sampleRate = 44100
	})
	client:update(100002)
	test.truthy(client:isLoading(), "buffering is still a load")
	test.equal(client.buffered, 0.4, "the decoded seconds ahead are kept")
	test.equal(client:position(), 0)
	test.equal(client:heardFrame(), 0, "nothing is heard while the device is held")

	-- Five seconds of ticks with the device still held: nothing may move.
	for at = 1, 5 do client:update(100002 + at) end
	test.equal(client:position(), 0, "the place does not move while nothing is heard")
	test.equal(client:heardFrame(), 0, "nor the heard frame")

	-- Enough is buffered: the device starts, and the first heard frames end the wait.
	events:push({
		kind = "snapshot",
		commandId = load.id,
		position = 0.1,
		duration = 120,
		playing = true,
		buffering = false,
		buffered = 2.5,
		heard = 4410,
		sampleRate = 44100
	})
	client:update(100010)
	test.falsy(client:isLoading(), "heard frames and a started device end the wait")
	test.equal(client:position(), 0.1)
	client:update(100011)
	test.truthy(client:position() > 0.5, "the place moves again once it plays")
	test.truthy(client:heardFrame() > 4410)

	client:shutdown()
end)

test.it("never lets the place pass the end of the track", function()
	local commands = threading.channel()
	local events = threading.channel()
	local client = AudioClient.attach(commands, events, nil)

	client:load({ "/a.wav" }, 0, true, false)
	local load = commands:pop() --[[@as beat.AudioMessage]]
	events:push({
		kind = "snapshot",
		commandId = load.id,
		position = 99,
		duration = 100,
		playing = true,
		heard = 99 * 44100,
		sampleRate = 44100
	})
	client:update(10)
	client:update(60)
	test.equal(client:position(), 100, "a minute of ticks cannot walk past the length")

	client:shutdown()
end)

test.it("pauses a track the thread is still buffering, keeping its snapshot place", function()
	local commands = threading.channel()
	local events = threading.channel()
	local client = AudioClient.attach(commands, events, nil)

	client:load({ "/a.wav" }, 0, true, false)
	local load = commands:pop() --[[@as beat.AudioMessage]]
	events:push({
		kind = "snapshot",
		commandId = load.id,
		position = 0,
		duration = 100,
		playing = false,
		buffering = true,
		buffered = 0.2,
		heard = 0,
		sampleRate = 44100
	})
	client:update(4)
	test.truthy(client:isLoading())

	client:pause()
	test.falsy(client:isLoading(), "the pause ends the load at once")
	test.falsy(client:isPlaying())
	local pause = commands:pop() --[[@as beat.AudioMessage]]
	test.equal(pause.kind, "pause", "the thread is told to stop holding the device")
	test.equal(client:position(), 0, "the place is the snapshot's, not an interpolated one")

	-- A snapshot from before the pause cannot put the wait back.
	events:push({
		kind = "snapshot",
		commandId = load.id,
		position = 0,
		duration = 100,
		playing = false,
		buffering = true,
		buffered = 0.2,
		heard = 0,
		sampleRate = 44100
	})
	client:update(5)
	test.falsy(client:isLoading(), "a stale buffering snapshot is not the truth again")

	-- Playing again asks the thread to start, and waits while it buffers.
	client:play()
	test.truthy(client:isLoading())
	local play = commands:pop() --[[@as beat.AudioMessage]]
	test.equal(play.kind, "play")

	client:shutdown()
end)

test.it("answers a stop at once, before the audio thread has caught up", function()
	local commands = threading.channel()
	local events = threading.channel()
	local client = AudioClient.attach(commands, events, nil)

	client:load({ "/a.wav" }, 0, true, false)
	commands:pop()
	client:update(1)
	test.truthy(client:isPlaying())

	client:pause()
	test.falsy(client:isPlaying())
	local pausedAt = client:position()

	-- A snapshot from before the pause must not put the player back into play.
	events:push({ kind = "snapshot", position = pausedAt + 1, duration = 100, playing = true, heard = 0, sampleRate = 44100, commandId = 1 })
	client:update(1.5)
	test.falsy(client:isPlaying())
	test.equal(client:position(), pausedAt, "the pause position is what was on screen")

	client:seek(50)
	test.equal(client:position(), 50)

	client:update(1.6)
	test.equal(client:position(), 50)

	client:shutdown()
end)

test.it("is loading until the requested track is heard", function()
	local commands = threading.channel()
	local events = threading.channel()
	local client = AudioClient.attach(commands, events, nil)

	client:load({ "/a.wav" }, 0, true, false)
	local load = commands:pop() --[[@as beat.AudioMessage]]
	test.truthy(client:isLoading(), "a requested track is loading before a snapshot")

	-- The command is applied, but the device has not played a frame of the track yet.
	events:push({
		kind = "snapshot", commandId = load.id, playing = true, heard = 0, position = 0,
		duration = 100, sampleRate = 44100
	})
	client:update(1)
	test.truthy(client:isLoading(), "a snapshot with no heard frames is still loading")

	events:push({
		kind = "snapshot", commandId = load.id, playing = true, heard = 4410, position = 0.1,
		duration = 100, sampleRate = 44100
	})
	client:update(1.1)
	test.falsy(client:isLoading(), "heard frames end the wait")

	-- Pausing a track that is still being opened stops the wait, and so does an error.
	client:load({ "/b.wav" }, 0, true, false)
	commands:pop() --[[@as beat.AudioMessage]]
	test.truthy(client:isLoading())
	client:pause()
	test.falsy(client:isLoading(), "a pause ends the wait")
	client:play()
	test.truthy(client:isLoading())
	events:push({ kind = "error", message = "the file went away" })
	client:update(3)
	test.falsy(client:isLoading(), "an error ends the wait")

	client:shutdown()
end)

test.it("a seek keeps the clocks real and shows its target at once", function()
	local commands = threading.channel()
	local events = threading.channel()
	local client = AudioClient.attach(commands, events, nil)

	client:load({ "/a.wav" }, 0, true, false)
	local load = commands:pop() --[[@as beat.AudioMessage]]
	events:push({
		kind = "snapshot", commandId = load.id, playing = true, heard = 60 * 44100,
		position = 60, duration = 100, sampleRate = 44100
	})
	client:update(1)
	test.equal(client:position(), 60)

	client:seek(65)
	local seek = commands:pop() --[[@as beat.AudioMessage]]
	test.equal(seek.seconds, 65)
	test.falsy(client:isLoading(), "a seek is not a fresh track")
	test.equal(client:position(), 65, "the bar shows the target at once")
	test.equal(client:duration(), 100, "and keeps the length")

	-- A snapshot from before the seek describes the old place: it must not pull the bar back.
	events:push({
		kind = "snapshot", commandId = load.id, playing = true, heard = 60 * 44100,
		position = 60, duration = 100, sampleRate = 44100
	})
	client:update(1.1)
	test.equal(client:position(), 65, "a stale snapshot leaves the target on the bar")
	test.equal(client:duration(), 100)

	-- The thread pauses the device to refill the ring at the new place. The track has been heard,
	-- so neither clock is a placeholder, and the bar holds the target rather than the old place.
	events:push({
		kind = "snapshot", commandId = seek.id, playing = false, buffering = true, buffered = 0.2,
		position = 65, duration = 100, heard = 0, sampleRate = 44100
	})
	client:update(1.2)
	test.truthy(client:hasHeard(), "the track was heard before the seek")
	test.falsy(client:isLoading(), "a seek's re-buffer is not a new track")
	test.truthy(client:isPlaying(), "the user still wants playback through the seek")
	test.falsy(client:isAudible())
	test.equal(client:position(), 65, "the bar holds the target while the ring refills")
	test.equal(client:duration(), 100)

	-- The device reads again from the target, and the place moves on from there.
	events:push({
		kind = "snapshot", commandId = seek.id, playing = true, buffering = false, buffered = 1.5,
		position = 65.02, duration = 100, heard = 882, sampleRate = 44100
	})
	client:update(1.3)
	test.falsy(client:isLoading())
	test.equal(client:position(), 65.02)
	client:update(1.9)
	test.truthy(client:position() > 65.4, "the place advances from the seek target")

	client:shutdown()
end)

test.it("adds quick repeated seeks up from the last target", function()
	local commands = threading.channel()
	local events = threading.channel()
	local client = AudioClient.attach(commands, events, nil)

	client:load({ "/a.wav" }, 0, true, false)
	local load = commands:pop() --[[@as beat.AudioMessage]]
	events:push({
		kind = "snapshot", commandId = load.id, playing = true, heard = 60 * 44100,
		position = 60, duration = 100, sampleRate = 44100
	})
	client:update(1)
	test.equal(client:position(), 60)

	-- Three arrow-key seek messages in a row, as holding the key sends them.
	client:seek(client:position() + 5)
	local first = commands:pop() --[[@as beat.AudioMessage]]
	client:seek(client:position() + 5)
	local second = commands:pop() --[[@as beat.AudioMessage]]
	client:seek(client:position() + 5)
	local third = commands:pop() --[[@as beat.AudioMessage]]
	test.equal(first.seconds, 65)
	test.equal(second.seconds, 70)
	test.equal(third.seconds, 75)
	test.equal(client:position(), 75, "each step starts from the last target")

	-- An answer to the first seek arriving late cannot pull the bar back.
	events:push({
		kind = "snapshot", commandId = first.id, playing = false, buffering = true,
		position = 65, duration = 100, heard = 0, sampleRate = 44100
	})
	client:update(1.1)
	test.equal(client:position(), 75)

	-- The last seek's re-buffer, with no length to give, still keeps the real one.
	events:push({
		kind = "snapshot", commandId = third.id, playing = false, buffering = true,
		position = 75, duration = 0, heard = 0, sampleRate = 44100
	})
	client:update(1.2)
	test.equal(client:position(), 75)
	test.equal(client:duration(), 100, "the length is not lost to a buffering snapshot")

	events:push({
		kind = "snapshot", commandId = third.id, playing = true, buffering = false,
		position = 75.01, duration = 100, heard = 441, sampleRate = 44100
	})
	client:update(1.3)
	test.equal(client:position(), 75.01)

	client:shutdown()
end)

test.it("releases a blocked audio thread without waiting or closing its channels", function()
	local commands = threading.channel()
	local events = threading.channel()
	local commandAddress, eventAddress = commands:address(), events:address()

	local handle = threading.spawn(function()
		local threading = require("threading")
		local inbox = threading.channelFromAddress(commandAddress)
		local outbox = threading.channelFromAddress(eventAddress)
		outbox:push({ kind = "ready" })
		threading.sleep(300)
		while true do
			local command = inbox:pop() --[[@as any]]
			if command == nil then
				inbox:wait(20)
			elseif type(command) == "table" and command.kind == "quit" then
				break
			end
		end
		outbox:push({ kind = "stopped" })
		inbox:close()
		outbox:close()
	end)

	test.truthy(events:wait(2000))
	test.equal(events:pop() --[[@as table]].kind, "ready")

	local client = AudioClient.attach(commands, events, handle)
	local started = time.now()
	client:release()
	test.truthy(time.now() - started < 0.1, "release does not wait for the thread")

	-- The channels are still open: the thread has not finished with them.
	test.truthy(commands:push({ kind = "still-open" }), "release leaves the channels to the thread")

	test.truthy(events:wait(2000))
	test.equal(events:pop() --[[@as table]].kind, "stopped")
	handle:join()
	commands:close()
	events:close()
end)

test.it("does not close the channels of a thread it could not join", function()
	local commands = threading.channel()
	local events = threading.channel()
	local commandAddress, eventAddress = commands:address(), events:address()

	local handle = threading.spawn(function()
		local threading = require("threading")
		local inbox = threading.channelFromAddress(commandAddress)
		local outbox = threading.channelFromAddress(eventAddress)
		outbox:push({ kind = "ready" })
		threading.sleep(500)
		while true do
			local command = inbox:pop() --[[@as any]]
			if command == nil then
				inbox:wait(20)
			elseif type(command) == "table" and command.kind == "quit" then
				break
			end
		end
		outbox:push({ kind = "stopped" })
		inbox:close()
		outbox:close()
	end)

	test.truthy(events:wait(2000))
	test.equal(events:pop() --[[@as table]].kind, "ready")

	local client = AudioClient.attach(commands, events, handle)
	local joined = client:shutdown()
	test.falsy(joined, "a thread still sleeping could not be joined")
	test.truthy(commands:push({ kind = "kept" }), "the channels are kept for the thread")

	test.truthy(events:wait(3000))
	test.equal(events:pop() --[[@as table]].kind, "stopped")
	handle:join()
	commands:close()
	events:close()
end)

-- A source on a slow network mount blocks the thread reading it. The app thread must be free while
-- that happens: it drains events and interpolates the position nothing else can move.
test.it("does not block the app thread while the audio thread is stuck reading", function()
	local commands = threading.channel()
	local events = threading.channel()
	local commandAddress, eventAddress = commands:address(), events:address()

	local worker = threading.spawn(function()
		local threading = require("threading")
		local inbox = threading.channelFromAddress(commandAddress)
		local outbox = threading.channelFromAddress(eventAddress)
		local position = 0
		local rate = 44100

		for _ = 1, 24 do
			-- A read that takes this long in the audio thread is a frame frozen, if it were here.
			threading.sleep(10)
			position += 0.6
			outbox:push({
				kind = "snapshot",
				position = position,
				duration = 180,
				playing = true,
				heard = position * rate,
				sampleRate = rate,
				written = position * rate + rate,
				floor = 0,
				commandId = 0
			})
		end

		local quit = inbox:pop()
		while quit == nil do
			inbox:wait(10)
			quit = inbox:pop()
		end
		inbox:close()
		outbox:close()
	end)

	local client = AudioClient.attach(commands, events, worker)
	local now = 0
	client:update(now)

	local worst = 0
	local first = nil
	for _ = 1, 100 do
		threading.sleep(2)
		now += 1 / 60
		local started = time.now()
		client:update(now)
		local elapsed = time.now() - started
		if elapsed > worst then worst = elapsed end
		local position = client:position()
		if first == nil then first = position end
	end

	test.truthy(worst < 0.005, string.format("the app thread's step stayed under 5 ms (worst %.3f ms)", worst * 1000))
	test.truthy(client:position() > first, "the playhead kept moving between the snapshots")
	test.truthy(client:isPlaying())

	client:shutdown()
end)

test.it("says a track that ends with nothing after it is the last, and starts nothing", function()
	local state = {
		index = 1,
		tracks = { { path = "tests/fixtures/tone.wav", sampleRate = 44100, channels = 1 } },
		sources = {},
		repeatOne = false,
		commandId = 3,
		sampleRate = nil,
		device = nil
	}
	---@type beat.AudioMessage[]
	local events = {}
	local player = AudioThread.open(state, function(event) events[#events + 1] = event end, nil)

	-- The buffer's last track playing out: treble says so through the same callback.
	assert(player.onTrackEnd)()

	test.equal(events[1].kind, "ended")
	test.equal(events[1].last, true, "nothing is staged or repeated after it")
	test.equal(events[2].kind, "snapshot", "and no track is announced as started")
	test.equal(events[2].playing, false)
	test.equal(#events, 2)

	player:close()
end)

test.it("keeps the play button after a stale snapshot says the last track is still playing", function()
	local commands = threading.channel()
	local events = threading.channel()
	local client = AudioClient.attach(commands, events, nil)
	local Player = require("beat.app.services.playback.player")

	---@type beat.Track
	local track = {
		id = 1,
		albumId = 1,
		path = "/a.wav",
		title = "A",
		artist = "A",
		album = "A",
		albumArtist = "A",
		artistId = 1,
		disc = 1,
		number = 1,
		duration = 100,
		format = "wav",
		sampleRate = 44100,
		channels = 1,
		hasPicture = false,
		modified = 0,
		hash = "a"
	}

	local player = Player.new()
	player.player = client
	client.onTrackEnd = function() player.pending = "ended" end
	player:playTracks({ track }, 1, {})

	---@type beat.AudioMessage?
	local load
	while true do
		local command = commands:pop() --[[@as beat.AudioMessage?]]
		if command == nil then break end
		if command.kind == "load" then load = command end
	end
	test.truthy(load ~= nil, "the queue was staged")

	events:push({
		kind = "snapshot", commandId = assert(load).id, playing = true, position = 0,
		duration = 100, heard = 0, sampleRate = 44100
	})
	player:update(1)
	test.truthy(player:isPlaying())

	-- The track ends with nothing next, and right behind that comes a snapshot taken before the
	-- end. It must not turn the pause button back on.
	events:push({ kind = "ended", completed = true, last = true })
	events:push({
		kind = "snapshot", commandId = load.id, playing = true, position = 100,
		duration = 100, heard = 4410000, sampleRate = 44100
	})
	local moved, structural = player:update(2)
	test.falsy(moved)
	test.truthy(structural, "the bar is laid out again for the stopped state")
	test.falsy(player:isPlaying(), "the play button comes back with the last track")

	local stopped = false
	while true do
		local command = commands:pop() --[[@as beat.AudioMessage?]]
		if command == nil then break end
		if command.kind == "stop" then stopped = true end
	end
	test.truthy(stopped, "the audio thread is told playback stopped")

	-- Even a later copy of that old snapshot cannot put it back.
	events:push({
		kind = "snapshot", commandId = load.id, playing = true, position = 100,
		duration = 100, heard = 4410000, sampleRate = 44100
	})
	player:update(3)
	test.falsy(player:isPlaying())

	player:destroy()
end)

test.it("backs off a buffering wait after a second without new audio", function()
	local source = gateSource(0)
	---@type beat.AudioThread.State
	local state = { index = 1, sources = { source }, wantsPlay = true, buffering = true }

	test.falsy(AudioThread.bufferProgress(state, 100), "the first look starts the clock")
	test.falsy(AudioThread.bufferProgress(state, 100.9), "just under a second is still the fast poll")
	test.truthy(AudioThread.bufferProgress(state, 101), "a second with no frames backs off")

	source.frames = 4410
	test.falsy(AudioThread.bufferProgress(state, 101.5), "data arriving puts the fast poll back")
	test.falsy(AudioThread.bufferProgress(state, 102.4))
	test.truthy(AudioThread.bufferProgress(state, 102.5))

	source.frames = 0
	test.falsy(AudioThread.bufferProgress(state, 103), "a different source is a new wait")

	state.buffering = false
	test.falsy(AudioThread.bufferProgress(state, 104), "not buffering has nothing to back off")
	test.equal(state.bufferWaitAt, nil)
end)
