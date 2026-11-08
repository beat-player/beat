-- What playback tells the rest of the app: a track starting or stopping, and the queue changing.
-- The player's own edges are in `player.test.lua`; these tests are about the messages the service
-- puts on `emit` for the moment each transition happens.
local test = require("lde-test")
local fs = require("fs")
local paths = require("beat.paths")
local Playback = require("beat.app.services.playback")
local Queue = require("beat.app.services.playback.queue")

-- A session restored while a test runs must not read or write the user's own.
local configDirectory = os.tmpname() .. "-beat-playback-events"
os.remove(configDirectory)
fs.mkdirAll(configDirectory)

local realDirectory = paths.directory
paths.directory = function() return configDirectory end

test.afterAll(function()
	paths.directory = realDirectory
	fs.rmdir(configDirectory)
end)

local function track(id, albumId, path)
	return {
		id = id,
		albumId = albumId,
		path = path,
		title = "Track " .. id,
		artist = "Artist",
		album = "Album",
		duration = 120,
	}
end

local albumA = {
	id = 10,
	title = "First",
	tracks = {
		track(1, 10, "/tmp/a1.wav"),
		track(2, 10, "/tmp/a2.wav"),
	},
}

local albumB = {
	id = 20,
	title = "Second",
	tracks = {
		track(3, 20, "/tmp/b1.wav"),
		track(4, 20, "/tmp/b2.wav"),
	},
}

local function libraryOf(albums)
	local tracks = {}
	local byId = {}
	for _, album in ipairs(albums) do
		byId[album.id] = album
		for _, song in ipairs(album.tracks) do tracks[#tracks + 1] = song end
	end

	local current = { tracks = tracks, albums = albums}
	function current:album(id) return byId[id] end
	function current:track(id)
		for _, song in ipairs(self.tracks) do
			if song.id == id then return song end
		end
		return nil
	end
	return { current = current}
end

-- A device that knows whether it plays, because a pause and a resume are not a track transition.
local function device(player)
	local state = { playing = false, enqueued = {}}
	player.player = {
		close = function() state.enqueued = {} end,
		enqueue = function(_, path) state.enqueued[#state.enqueued + 1] = path end,
		play = function() state.playing = true end,
		pause = function() state.playing = false end,
		stop = function() state.playing = false end,
		seek = function() end,
		update = function() end,
		position = function() return 0 end,
		isPlaying = function() return state.playing end,
		setVolume = function() end,
	}
	return state
end

local function start(albums)
	local messages = {}
	local toasts = { shown = {}}
	local service = Playback.new({
		settings = { values = { volume = 0.5, isMuted = false}, changed = function() end },
		library = libraryOf(albums or { albumA, albumB}),
		collections = { recordListen = function() end },
		toasts = {
			show = function(_, text, tone) toasts.shown[#toasts.shown + 1] = { text = text, tone = tone} end,
		},
		emit = function(message) messages[#messages + 1] = message end,
	})
	device(service.player)
	return service, messages, toasts
end

local function clear(messages)
	for at = #messages, 1, -1 do messages[at] = nil end
end

local function kinds(messages)
	local list = {}
	for _, message in ipairs(messages) do list[#list + 1] = message.type end
	return list
end

test.it("announces a queue replacing what plays, then the track that starts", function()
	local service, messages = start()
	service:playAlbum(albumA.id, false)

	test.equal(#messages, 2)
	test.equal(messages[1].type, "queueChanged")
	test.equal(messages[2].type, "trackStarted")
	test.equal(messages[2].track.id, 1)
	test.equal(messages[2].position, 0)
end)

test.it("ends the old track and starts the new one on a manual skip", function()
	local service, messages = start()
	service:playAlbum(albumA.id, false)
	clear(messages)

	service.player:next()

	test.equal(#messages, 2)
	test.equal(messages[1].type, "trackEnded")
	test.equal(messages[2].type, "trackStarted")
	test.equal(messages[1].track.id, 1)
	test.equal(messages[1].completed, false)
	test.equal(messages[2].track.id, 2)
	test.equal(messages[2].position, 0)
end)

test.it("counts an automatic track end as completed and starts the one that follows", function()
	local service, messages = start()
	service:playAlbum(albumA.id, false)
	clear(messages)

	service.player.pending = "ended"
	service:step(0)

	test.equal(#messages, 2)
	test.equal(messages[1].type, "trackEnded")
	test.equal(messages[1].track.id, 1)
	test.equal(messages[1].completed, true)
	test.equal(messages[2].type, "trackStarted")
	test.equal(messages[2].track.id, 2)
end)

test.it("restarts repeat-one as an ended track and the same track starting", function()
	local service, messages = start()
	service:playAlbum(albumA.id, false)
	service.player:cycleRepeat() -- off to all
	service.player:cycleRepeat() -- all to one
	clear(messages)

	service.player.pending = "ended"
	service:step(0)

	test.equal(#messages, 2)
	test.equal(messages[1].type, "trackEnded")
	test.equal(messages[1].track.id, 1)
	test.equal(messages[1].completed, true)
	test.equal(messages[2].type, "trackStarted")
	test.equal(messages[2].track.id, 1)
	test.equal(messages[2].position, 0)
end)

test.it("ends a track when playback stops and says nothing on pause or resume", function()
	local service, messages = start()
	service:playAlbum(albumA.id, false)
	clear(messages)

	service:pause()
	test.equal(#messages, 0, "a pause does not stop the track being the one playing")

	service:play()
	test.equal(#messages, 0, "a resume is the same track carrying on")

	service:stop()
	test.equal(#messages, 1)
	test.equal(messages[1].type, "trackEnded")
	test.equal(messages[1].track.id, 1)
	test.equal(messages[1].completed, false)

	service:play()
	test.equal(#messages, 2)
	test.equal(messages[2].type, "trackStarted")
	test.equal(messages[2].track.id, 1, "playing after stop starts the track again")
	test.equal(messages[2].position, 0)
end)

test.it("starts a restored session at the place it was left", function()
	local service, messages = start()
	service.player:restore(Queue.new(albumA.tracks, 1), 37)
	clear(messages)

	service:play()

	test.equal(#messages, 1)
	test.equal(messages[1].type, "trackStarted")
	test.equal(messages[1].track.id, 1)
	test.equal(messages[1].position, 37, "the payload says where playback begins")
end)

test.it("ends the last track of the queue without starting another", function()
	local service, messages = start()
	service:playAlbum(albumA.id, false)
	service.player:jump(albumA.tracks[2].id)
	clear(messages)

	service.player.pending = "ended"
	service:step(0)

	test.equal(#messages, 1)
	test.equal(messages[1].type, "trackEnded")
	test.equal(messages[1].track.id, 2)
	test.equal(messages[1].completed, true)
end)

test.it("says the queue changed when a new one replaces it, without losing either track", function()
	local service, messages = start()
	service:playAlbum(albumA.id, false)
	clear(messages)

	service:playAlbum(albumB.id, false)

	test.equal(#messages, 3)
	test.equal(messages[1].type, "queueChanged")
	test.equal(messages[2].type, "trackEnded")
	test.equal(messages[2].track.id, 1)
	test.equal(messages[2].completed, false)
	test.equal(messages[3].type, "trackStarted")
	test.equal(messages[3].track.id, 3)
end)

test.it("says the queue changed when it is shuffled, without a track transition", function()
	local service, messages = start()
	service:playAlbum(albumA.id, false)
	clear(messages)

	service:update({ type = "shuffle"})
	test.equal(#messages, 1)
	test.equal(messages[1].type, "queueChanged")

	service:update({ type = "shuffle"})
	test.equal(#messages, 2)
	test.equal(messages[2].type, "queueChanged")
end)

test.it("puts an album next and plays it when the current track ends", function()
	local service, messages, toasts = start()
	service:playAlbum(albumA.id, false)
	clear(messages)

	service:update({ type = "queueAlbum", id = albumB.id, next = true})

	test.equal(#messages, 1)
	test.equal(messages[1].type, "queueChanged")
	test.equal(toasts.shown[1].text, "Playing next · Second")
	test.equal(service.player.queue.order[2], 3, "the album's first track is after the current one")
	test.equal(service.player.pendingNextAt, 2)

	clear(messages)
	service.player.pending = "ended"
	service:step(0)

	test.equal(kinds(messages)[1], "trackEnded")
	test.equal(messages[1].completed, true)
	test.equal(kinds(messages)[2], "trackStarted")
	test.equal(messages[2].track.id, 3, "the queued album starts at the boundary")
end)

test.it("adds an album to the end of the queue", function()
	local service, messages, toasts = start()
	service:playAlbum(albumA.id, false)
	clear(messages)

	service:update({ type = "queueAlbum", id = albumB.id})

	test.equal(#messages, 1)
	test.equal(messages[1].type, "queueChanged")
	test.equal(toasts.shown[1].text, "Added to queue · Second")
	test.falsy(service.player.pendingNextAt)
	test.equal(service.player.queue.order[3], 3, "the album follows everything already queued")
	test.equal(service.player.queue.order[4], 4)
end)
