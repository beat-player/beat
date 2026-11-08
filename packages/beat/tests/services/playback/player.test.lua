-- The player's own edges: a manual start ramps the device volume, while the queue and repeat
-- rules stay in the player. The audio device is a stand-in; treble has tests for its own side.
local test = require("lde-test")
local Player = require("beat.app.services.playback.player")
local Queue = require("beat.app.services.playback.queue")

local function standIn(player)
	local volumes = {}
	player.player = {
	close = function() end,
	enqueue = function() end,
	play = function() end,
	pause = function() end,
	stop = function() end,
	update = function() end,
	position = function() return 0 end,
	isPlaying = function() return true end,
	setVolume = function(_, value) volumes[#volumes + 1] = value end,
	}
	return volumes
end

local track = {
id = 1,
path = "/tmp/track.wav",
title = "Track",
artist = "Artist",
album = "Album",
duration = 120,
}

test.it("fades a manual start in over 120 ms", function()
	local player = Player.new()
	local volumes = standIn(player)
	player:playTracks({ track}, 1)

	test.equal(#volumes, 1)
	test.equal(volumes[1], 0, "the first frame is silent")
	test.equal(player.fadeGain, 0)
	test.truthy(player.fadeActive)

	player:update(100)
	test.equal(player.fadeGain, 0)

	player:update(100.06)
	test.truthy(player.fadeGain > 0.8 and player.fadeGain < 1, "the ramp is part-way")

	player:update(100.12)
	test.equal(player.fadeGain, 1)
	test.falsy(player.fadeActive)
	test.equal(volumes[#volumes], 1)
end)

test.it("does not fade when the queue repeats the same track", function()
	local player = Player.new()
	local volumes = standIn(player)
	player:playTracks({ track}, 1, { repeatMode = "one"})
	player:update(100)
	player:update(100.12)
	test.equal(player.fadeGain, 1)

	player.pending = "ended"
	player:update(100.2)
	test.equal(player.fadeGain, 1, "an automatic repeat starts at the target volume")
	test.equal(volumes[#volumes], 1)
end)

test.it("changes repeat and shuffle without touching the current audio", function()
	local tracks = {
	{ id = 1, title = "One", artist = "Artist", album = "Album", duration = 100,
	path = "/one.flac"},
	{ id = 2, title = "Two", artist = "Artist", album = "Album", duration = 100,
	path = "/two.flac"},
	{ id = 3, title = "Three", artist = "Artist", album = "Album", duration = 100,
	path = "/three.flac"},
	}
	local touched = 0
	local player = Player.new()
	player.player = {
	isPlaying = function() return true end,
	position = function() return 42 end,
	duration = function() return 100 end,
	close = function() touched = touched + 1 end,
	enqueue = function() touched = touched + 1 end,
	play = function() touched = touched + 1 end,
	pause = function() touched = touched + 1 end,
	seek = function() touched = touched + 1 end,
	stop = function() touched = touched + 1 end,
	update = function() end,
	setVolume = function() end,
	}
	player:playTracks(tracks, 1)
	touched = 0

	player:cycleRepeat()
	player:setShuffle(true)

	test.equal(touched, 0, "the button changes settings, not the running queue")
	test.equal(player.queue.repeatMode, "all")
	test.truthy(player.queue.shuffle)
	test.truthy(player.orderDirty, "the staged queue is known to be out of date")
end)

test.it("hands a shuffle change over at the track boundary", function()
	local tracks = {
	{ id = 1, title = "One", artist = "Artist", album = "Album", duration = 100,
	path = "/one.flac"},
	{ id = 2, title = "Two", artist = "Artist", album = "Album", duration = 100,
	path = "/two.flac"},
	{ id = 3, title = "Three", artist = "Artist", album = "Album", duration = 100,
	path = "/three.flac"},
	}
	local closes = 0
	local player = Player.new()
	player.player = {
	isPlaying = function() return true end,
	position = function() return 100 end,
	duration = function() return 100 end,
	close = function() closes = closes + 1 end,
	enqueue = function() end,
	play = function() end,
	pause = function() end,
	seek = function() end,
	stop = function() end,
	update = function() end,
	setVolume = function() end,
	}
	player:playTracks(tracks, 1)
	closes = 0

	player:setShuffle(true)
	player.pending = "ended"
	player:update(100)

	test.truthy(closes > 0, "the boundary reload applies the new order")
	test.falsy(player.orderDirty, "the staged queue now matches the setting")
	test.equal(player.queue.position, 2)
	test.truthy(player.queue:current().id ~= 1, "the next track comes from the shuffled rest")
end)

test.it("leaves a repeat-all change to the existing queue", function()
	local tracks = {
	{ id = 1, title = "One", artist = "Artist", album = "Album", duration = 100,
	path = "/one.flac"},
	{ id = 2, title = "Two", artist = "Artist", album = "Album", duration = 100,
	path = "/two.flac"},
	}
	local closes = 0
	local player = Player.new()
	player.player = {
	isPlaying = function() return true end,
	position = function() return 100 end,
	duration = function() return 100 end,
	close = function() closes = closes + 1 end,
	enqueue = function() end,
	play = function() end,
	pause = function() end,
	seek = function() end,
	stop = function() end,
	update = function() end,
	setVolume = function() end,
	}
	player:playTracks(tracks, 1)
	closes = 0

	player:cycleRepeat()
	player.pending = "ended"
	player:update(100)

	test.equal(closes, 0, "repeat-all only changes what happens at the queue's end")
	test.equal(player.queue.position, 2)
	test.equal(player.queue.repeatMode, "all")
	test.equal(player.loadedRepeatMode, "off", "the staged queue did not need reloading")
end)

test.it("applies repeat-one at the boundary instead of on the button", function()
	local tracks = {
	{ id = 1, title = "One", artist = "Artist", album = "Album", duration = 100,
	path = "/one.flac"},
	{ id = 2, title = "Two", artist = "Artist", album = "Album", duration = 100,
	path = "/two.flac"},
	}
	local closes = 0
	local player = Player.new()
	player.player = {
	isPlaying = function() return true end,
	position = function() return 100 end,
	duration = function() return 100 end,
	close = function() closes = closes + 1 end,
	enqueue = function() end,
	play = function() end,
	pause = function() end,
	seek = function() end,
	stop = function() end,
	update = function() end,
	setVolume = function() end,
	}
	player:playTracks(tracks, 1)
	closes = 0

	player:cycleRepeat() -- off to all
	player:cycleRepeat() -- all to one
	test.equal(closes, 0, "the button only changes the mode")
	player.pending = "ended"
	player:update(100)

	test.truthy(closes > 0, "repeat-one reloads when the track ends")
	test.equal(player.loadedRepeatMode, "one")
	test.equal(player.queue:current().id, 1)
end)

test.it("queues the next album without touching the current audio", function()
	local tracks = {
	{ id = 1, title = "One", artist = "Artist", album = "Album", duration = 100,
	path = "/one.flac"},
	{ id = 2, title = "Two", artist = "Artist", album = "Album", duration = 100,
	path = "/two.flac"},
	{ id = 3, title = "Three", artist = "Artist", album = "Album", duration = 100,
	path = "/three.flac"},
	}
	local touched = 0
	local player = Player.new()
	player.queue = Queue.new(tracks, 1, {})
	player.player = {
	close = function() touched = touched + 1 end,
	enqueue = function() touched = touched + 1 end,
	play = function() touched = touched + 1 end,
	pause = function() touched = touched + 1 end,
	seek = function() touched = touched + 1 end,
	setVolume = function() touched = touched + 1 end,
	isPlaying = function() return true end,
	position = function() return 40 end,
	}

	player:playNext({ tracks[3]})

	test.equal(touched, 0, "the current output is not reloaded or seeked")
	test.equal(player.queue.order[2], 4, "but the next track is queued after the current one")
	test.equal(player.pendingNextAt, 2, "and applied when the current track ends")
end)

-- A device that knows whether it is playing and what it was handed, for the tests that start and
-- stop it: the stand-in above is always playing.
local function device(player)
	local calls = { closes = 0, enqueued = {}, seeks = {}}
	local playing = false
	player.player = {
	close = function()
		calls.closes = calls.closes + 1
		calls.enqueued = {}
	end,
	enqueue = function(_, path) calls.enqueued[#calls.enqueued + 1] = path end,
	play = function() playing = true end,
	pause = function() playing = false end,
	stop = function() playing = false end,
	seek = function(_, seconds) calls.seeks[#calls.seeks + 1] = seconds end,
	update = function() end,
	position = function() return 0 end,
	isPlaying = function() return playing end,
	setVolume = function() end,
	}
	return calls
end

local album = {
{ id = 1, path = "/tmp/one.wav", title = "One", artist = "Artist", album = "Album", duration = 120},
{ id = 2, path = "/tmp/two.wav", title = "Two", artist = "Artist", album = "Album", duration = 120},
{ id = 3, path = "/tmp/three.wav", title = "Three", artist = "Artist", album = "Album", duration = 120},
}

test.it("stops with the queue kept, and plays the same track again from the top", function()
	local player = Player.new()
	local calls = device(player)
	player:playTracks(album, 2)
	test.truthy(player:isPlaying())

	player:stop()
	test.falsy(player:isPlaying())
	test.equal(player.queue:current().id, 2, "the track stays current")

	local closes = calls.closes
	player:play()
	test.truthy(player:isPlaying())
	test.equal(calls.closes, closes + 1, "the queue is staged again rather than resumed")
	test.equal(calls.enqueued[1], "/tmp/two.wav", "from the track that was stopped")
	test.equal(#calls.enqueued, 2, "with the rest of the queue behind it")
end)

test.it("goes on from a pause without staging the queue again", function()
	local player = Player.new()
	local calls = device(player)
	player:playTracks(album, 1)
	local closes = calls.closes

	player:pause()
	test.falsy(player:isPlaying())
	player:play()
	test.truthy(player:isPlaying())
	test.equal(calls.closes, closes, "a resume is not a restart")

	player:play()
	test.truthy(player:isPlaying(), "play while playing changes nothing")
	test.equal(calls.closes, closes)
end)

test.it("opens no audio device for controls with nothing queued", function()
	local player = Player.new()
	player:pause()
	player:stop()
	player:play()
	test.equal(player.player, nil)
	test.falsy(player:isPlaying())
end)

test.it("comes back paused where it was, and plays on from there", function()
	local player = Player.new()
	player:restore(Queue.new(album, 2), 75)
	test.equal(player.player, nil, "putting a queue back opens no device")
	test.falsy(player:isPlaying())
	test.equal(player:current().id, 2)
	test.equal(player:position(), 75, "the bar shows where it was")

	player:seek(90)
	test.equal(player:position(), 90, "a seek before playing moves where it will start")

	local calls = device(player)
	player:play()
	test.truthy(player:isPlaying())
	test.equal(calls.enqueued[1], "/tmp/two.wav", "the queue is staged from the restored track")
	test.equal(calls.seeks[1], 90, "and plays from the place it was left at")
end)
