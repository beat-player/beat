-- What playback tells the rest of the app: a track starting or stopping, and the queue changing.
-- The player's own edges are in `player.test.lua`; these tests are about the messages the service
-- puts on `emit` for the moment each transition happens.
local test = require("lde-test")
local fs = require("fs")
local paths = require("beat.paths")
local Playback = require("beat.app.services.playback")
local Queue = require("beat.app.services.playback.queue")
local Library = require("beat.music.library")
local LibraryService = require("beat.app.services.library")
local Taxonomy = require("beat.app.services.collections.taxonomy")
local Toasts = require("beat.app.services.toasts")
local Signal = require("beat.app.signal")
local treble = require("treble")

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

---@param id number
---@param albumId number
---@param path string
---@return beat.Track
local function track(id, albumId, path)
	return {
		id = id,
		albumId = albumId,
		path = path,
		title = "Track " .. id,
		artist = "Artist",
		album = "Album",
		albumArtist = "Artist",
		artistId = 1,
		disc = 1,
		number = 1,
		duration = 120,
		format = "wav",
		sampleRate = 44100,
		channels = 2,
		hasPicture = false,
		modified = 0,
		hash = "track-" .. id,
	}
end

---@type beat.Album
local albumA = {
	id = 10,
	key = "first",
	title = "First",
	artist = "Artist",
	artistId = 1,
	tracks = {
		track(1, 10, "/tmp/a1.wav"),
		track(2, 10, "/tmp/a2.wav"),
	},
	duration = 240,
	trackCount = 2,
	modified = 0,
	hash = "first",
}

---@type beat.Album
local albumB = {
	id = 20,
	key = "second",
	title = "Second",
	artist = "Artist",
	artistId = 1,
	tracks = {
		track(3, 20, "/tmp/b1.wav"),
		track(4, 20, "/tmp/b2.wav"),
	},
	duration = 240,
	trackCount = 2,
	modified = 0,
	hash = "second",
}

---@param albums beat.Album[]
local function libraryOf(albums)
	local service = LibraryService.new({
		settings = { values = {} },
		options = { scan = false },
		emit = function() end,
	})

	---@type beat.Library
	local current = Library.new("/tmp/beat-playback-events")
	current.albums = albums
	for _, album in ipairs(albums) do
		current.albumById[album.id] = album
		for _, song in ipairs(album.tracks) do
			current.tracks[#current.tracks + 1] = song
			current.trackById[song.id] = song
		end
	end
	service.current = current
	return service
end

-- A device that knows whether it plays, because a pause and a resume are not a track transition.
---@param player beat.Player
---@return { playing: boolean, enqueued: string[] }
local function device(player)
	local state = { playing = false, enqueued = {} }

	local hardware = treble.Player.new({})
	hardware.close = function() state.enqueued = {} end
	hardware.enqueue = function(_, path)
		state.enqueued[#state.enqueued + 1] = path
		return hardware
	end
	hardware.play = function()
		state.playing = true
		return hardware
	end
	hardware.pause = function()
		state.playing = false
		return hardware
	end
	hardware.stop = function()
		state.playing = false
		return hardware
	end
	hardware.seek = function() return true end
	hardware.update = function() end
	hardware.position = function() return 0 end
	hardware.duration = function() return 0 end
	hardware.isPlaying = function() return state.playing end
	hardware.setVolume = function() return hardware end
	player.player = hardware
	return state
end

---@param albums beat.Album[]?
local function start(albums)
	---@type beat.Message[]
	local messages = {}

	---@type beat.Settings
	local settingsValues = {
		root = nil,
		theme = "night",
		accent = "lime",
		volume = 0.5,
		isMuted = false,
		sort = "title",
		view = "grid",
		sidebarWidth = 264,
		sidebarCollapsed = false,
		uiScale = 1,
		reduceMotion = false,
		lastfmSessionKey = "",
		lastfmUsername = "",
		lastfmEnabled = true,
	}

	local library = libraryOf(albums or { albumA, albumB })
	local toasts = Toasts.new({ pointer = function() return nil end })
	---@type beat.CollectionsService
	local collections = {
		taxonomy = Taxonomy.new(),
		library = library,
		toasts = toasts,
		changed = Signal.new(),
		recordListen = function() end,
	}
	local service = Playback.new({
		settings = { values = settingsValues },
		library = library,
		collections = collections,
		toasts = toasts,
		emit = function(message) messages[#messages + 1] = message end,
	})
	device(service.player)
	return service, messages, toasts
end

---@param messages beat.Message[]
local function clear(messages)
	for at = #messages, 1, -1 do messages[at] = nil end
end

---@param messages beat.Message[]
---@return string[]
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
	service.player:jump(assert(albumA.tracks[2]).id)
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
	test.equal(toasts.list[1].text, "Playing next · Second")
	test.equal(assert(service.player.queue).order[2], 3, "the album's first track is after the current one")
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
	test.equal(toasts.list[1].text, "Added to queue · Second")
	test.falsy(service.player.pendingNextAt)
	test.equal(assert(service.player.queue).order[3], 3, "the album follows everything already queued")
	test.equal(assert(service.player.queue).order[4], 4)
end)
