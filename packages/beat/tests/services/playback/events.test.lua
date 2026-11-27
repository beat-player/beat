-- What playback tells the rest of the app: a track starting or stopping, and the queue changing.
-- The player's own edges are in `player.test.lua`; these tests are about the messages the service
-- puts on `emit` for the moment each transition happens.
local test = require("lde-test")
local fs = require("fs")
local json = require("json")
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
		hash = "track-" .. id
	}
end

---@type beat.Album
local albumA = {
	id = 10,
	key = "first",
	title = "First",
	artist = "Artist",
	artistId = 1,
	tracks = { track(1, 10, "/tmp/a1.wav"), track(2, 10, "/tmp/a2.wav") },
	duration = 240,
	trackCount = 2,
	modified = 0,
	hash = "first"
}

---@type beat.Album
local albumB = {
	id = 20,
	key = "second",
	title = "Second",
	artist = "Artist",
	artistId = 1,
	tracks = { track(3, 20, "/tmp/b1.wav"), track(4, 20, "/tmp/b2.wav") },
	duration = 240,
	trackCount = 2,
	modified = 0,
	hash = "second"
}

-- An album long enough for a row in the middle to have tracks on both sides of it.
---@type beat.Album
local albumC = {
	id = 30,
	key = "third",
	title = "Third",
	artist = "Artist",
	artistId = 1,
	tracks = {
		track(5, 30, "/tmp/c1.wav"),
		track(6, 30, "/tmp/c2.wav"),
		track(7, 30, "/tmp/c3.wav"),
		track(8, 30, "/tmp/c4.wav"),
		track(9, 30, "/tmp/c5.wav")
	},
	duration = 600,
	trackCount = 5,
	modified = 0,
	hash = "third"
}

---@param albums beat.Album[]
local function libraryOf(albums)
	local service = LibraryService.new({ settings = { values = {} }, options = { scan = false }, emit = function() end })

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
		equalizerPreset = "flat",
		equalizerGains = { 0, 0, 0, 0, 0 },
		equalizerCustomPresets = {},
		disabledPlugins = {}
	}

	local library = libraryOf(albums or { albumA, albumB })
	local toasts = Toasts.new({ pointer = function() return nil end })
	---@type beat.CollectionsService
	local collections = {
		taxonomy = Taxonomy.new(),
		library = library,
		toasts = toasts,
		changed = Signal.new(),
		recordListen = function() end
	}
	local service = Playback.new(
		{
			settings = { values = settingsValues },
			library = library,
			collections = collections,
			toasts = toasts,
			emit = function(message) messages[#messages + 1] = message end
		}
	)
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
	local on = assert(Playback.on)
	service:playAlbum(albumA.id, false)
	clear(messages)

	on.shuffle(service, { type = "shuffle" })
	test.equal(#messages, 1)
	test.equal(messages[1].type, "queueChanged")

	on.shuffle(service, { type = "shuffle" })
	test.equal(#messages, 2)
	test.equal(messages[2].type, "queueChanged")
end)

test.it("puts an album next and plays it when the current track ends", function()
	local service, messages, toasts = start()
	local on = assert(Playback.on)
	service:playAlbum(albumA.id, false)
	clear(messages)

	on.queueAlbum(service, { type = "queueAlbum", id = albumB.id, next = true })

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

test.it("plays an album's row with the rest of the album after it", function()
	local service = start({ albumC })
	local on = assert(Playback.on)

	on.playTrack(service, { type = "playTrack", trackId = 7, albumId = albumC.id })

	local queue = assert(service.player.queue)
	test.equal(#queue.tracks, 5, "the queue is the whole album")
	test.equal(queue.position, 3, "the play head is the row that was tapped")
	test.equal(assert(queue:current()).id, 7, "it starts at the row that was tapped")
	test.equal(queue.order[queue.position + 1], 4, "the next track is the one after it in the album")
	test.equal(queue.source, "album", "the queue remembers it is the album")
end)

test.it("plays a listed row with the list in the order it was shown", function()
	local service = start({ albumC })
	local on = assert(Playback.on)

	-- A search result's own order is not the album's: the list is what the page showed.
	on.playTrack(service, { type = "playTrack", trackId = 7, trackIds = { 9, 5, 7, 6, 8 } })

	local queue = assert(service.player.queue)
	test.equal(#queue.tracks, 5, "the queue is the whole visible list")
	test.equal(assert(queue:current()).id, 7, "it starts at the row that was tapped")
	test.equal(assert(queue.tracks[queue.order[queue.position + 1]]).id, 6, "the row after it in the list comes next")
	test.equal(queue.source, "search", "the queue remembers it is a search")
end)

test.it("adds an album to the end of the queue", function()
	local service, messages, toasts = start()
	local on = assert(Playback.on)
	service:playAlbum(albumA.id, false)
	clear(messages)

	on.queueAlbum(service, { type = "queueAlbum", id = albumB.id })

	test.equal(#messages, 1)
	test.equal(messages[1].type, "queueChanged")
	test.equal(toasts.list[1].text, "Added to queue · Second")
	test.falsy(service.player.pendingNextAt)
	test.equal(assert(service.player.queue).order[3], 3, "the album follows everything already queued")
	test.equal(assert(service.player.queue).order[4], 4)
end)

test.it("asks for thirty frames a second while a track plays", function()
	local service = start()
	service:playAlbum(albumA.id, false)

	local _, busy = service:step(0)
	test.equal(busy, 1 / 30, "a playing track's playhead and meter move at thirty frames a second")

	service:pause()
	local _, idle = service:step(0)
	test.equal(idle, false, "a paused player with no meter easing asks for nothing")
end)

test.it("writes the session every thirty seconds while visible", function()
	local service = start()
	service:playAlbum(albumA.id, false)
	-- The queue change settles after SESSION_DELAY and is that baseline write.
	service:step(0)
	service:step(1)
	test.equal(service.sessionDueAt, nil, "the queue change was written")

	local position = 0
	local backend = assert(service.player.player)
	backend.position = function() return position end
	position = 29
	service:step(2)
	test.equal(service.sessionDueAt, nil, "a play head under the stride is not written")

	position = 30
	service:step(3)
	test.truthy(service.sessionDueAt ~= nil, "a stride reached schedules a write")
	service:step(4)
	test.equal(service.sessionDueAt, nil, "and writes it a second later")

	local saved = assert(json.decode(assert(fs.read(paths.file("session.json"))))):unpack()
	---@cast saved { seconds: number }
	test.equal(math.floor(saved.seconds), 30, "the file holds the place the stride reached")
end)

test.it("pauses a track that is still loading instead of starting it again", function()
	local service = start()
	local on = assert(Playback.on)
	service:playAlbum(albumA.id, false)

	local backend = assert(service.player.player)
	local state = { playing = true, loading = true, pauses = 0, plays = 0 }
	backend.isPlaying = function() return state.playing end
	backend.isLoading = function() return state.loading end
	backend.isAudible = function() return state.playing and not state.loading end
	backend.play = function()
		state.plays = state.plays + 1
		state.playing = true
	end
	backend.pause = function()
		state.pauses = state.pauses + 1
		state.playing = false
		state.loading = false
	end

	test.truthy(service.player:isPlaying(), "loading is playback the user asked for")
	service:toggle()
	test.equal(state.pauses, 1, "the transport pauses the load")
	test.equal(state.plays, 0, "and does not start it a second time")
	test.falsy(service.player:isPlaying())
	test.falsy(service:isLoading())

	-- The current track's row is the same control: tapping it pauses a loading track again.
	state.playing, state.loading = true, true
	on.playTrack(service, { type = "playTrack", trackId = 1 })
	test.equal(state.pauses, 2, "the current row pauses the load")
	test.equal(state.plays, 0)
end)

test.it("leaves the meter at rest while a track is still loading", function()
	local service = start()
	service:playAlbum(albumA.id, false)
	local backend = assert(service.player.player)
	local loading = true
	backend.isLoading = function() return loading end

	local stepped, cleared = 0, 0
	service.spectrum = {
		sync = function() end,
		step = function()
			stepped = stepped + 1
			return false, false
		end,
		clear = function()
			cleared = cleared + 1
		end
	}

	local _, busy, repaint = service:step(0)
	test.equal(stepped, 0, "no window is analysed while nothing of the track is heard")
	test.equal(cleared, 1, "the previous track's bars are cleared")
	test.truthy(busy, "the spinner still asks for frames")
	test.truthy(repaint)

	loading = false
	service:step(1)
	test.equal(stepped, 1, "the meter runs once the track is heard")
	test.equal(cleared, 1, "and is not cleared again")
end)

test.it("writes the session once a minute while hidden", function()
	local service = start()
	service:playAlbum(albumA.id, false)

	local position = 0
	local backend = assert(service.player.player)
	backend.position = function() return position end
	service:step(0)
	service:step(1)
	service.player:setBackground(true)
	service:flush()
	test.equal(service.sessionDueAt, nil)

	position = 59
	service:step(2)
	test.equal(service.sessionDueAt, nil, "under a hidden stride nothing is written")

	position = 60
	service:step(3)
	test.truthy(service.sessionDueAt ~= nil, "a minute hidden is a stride")
end)
