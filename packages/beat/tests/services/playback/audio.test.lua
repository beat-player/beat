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
	test.equal(calls[4], "play")
	test.equal(calls[5], "seek:12")
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

	-- A seek asks for a new place, and waits again until frames there are heard.
	client:seek(20)
	local seek = commands:pop() --[[@as beat.AudioMessage]]
	test.truthy(client:isLoading())
	events:push({
		kind = "snapshot", commandId = seek.id, playing = true, heard = 0, position = 20,
		duration = 100, sampleRate = 44100
	})
	client:update(2)
	test.truthy(client:isLoading(), "a seek's place is not a heard frame")
	events:push({
		kind = "snapshot", commandId = seek.id, playing = true, heard = 441, position = 20.01,
		duration = 100, sampleRate = 44100
	})
	client:update(2.1)
	test.falsy(client:isLoading())

	-- Pausing a track that is still being opened stops the wait, and so does an error.
	client:seek(30)
	test.truthy(client:isLoading())
	client:pause()
	test.falsy(client:isLoading(), "a pause ends the wait")
	client:seek(40)
	test.falsy(client:isLoading(), "a seek while paused asks for no audio yet")

	client:play()
	test.truthy(client:isLoading())
	events:push({ kind = "error", message = "the file went away" })
	client:update(3)
	test.falsy(client:isLoading(), "an error ends the wait")

	client:shutdown()
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
