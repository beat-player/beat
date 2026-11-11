-- The collections service owns the one moment a version-1 tags file can be moved onto audio keys:
-- it loads the file, it knows which library the app is showing, and it writes the file again. These
-- tests drive that wiring directly rather than through a whole app, so what they read is the file
-- on disk after an adoption.
local test = require("lde-test")
local fs = require("fs")
local json = require("json")
local paths = require("beat.paths")
local Library = require("beat.music.library")
local Collections = require("beat.app.services.collections")
local Signal = require("beat.app.signal")
local names = require("beat.music.names")

local configDirectory = os.tmpname() .. "-beat-collections"
os.remove(configDirectory)
fs.mkdirAll(configDirectory)

local realDirectory = paths.directory
paths.directory = function() return configDirectory end

test.afterAll(function()
	paths.directory = realDirectory
	fs.rmdir(configDirectory)
end)

local function clean()
	fs.delete(paths.file("tags.json"))
	fs.delete(paths.file("tags.v1.json"))
end

--- A library service enough for the collections service: the current library, and the three
--- signals it connects adoption to.
---@param current beat.Library?
local function libraryService(current)
	return { current = current, replaced = Signal.new(), changed = Signal.new(), finished = Signal.new() }
end

local toasts = { show = function() end }
---@cast toasts beat.ToastsService

---@param entries { path: string, fingerprint: string, title: string? }[]
local function library(entries)
	local lib = Library.new("/music")
	for _, item in ipairs(entries) do
		lib:add(
			{
				format = "FLAC",
				sampleRate = 44100,
				channels = 2,
				duration = 180,
				hasPicture = false,
				fingerprint = item.fingerprint,
				tags = { title = item.title or "Song", artist = "artist", album = "album", albumArtist = "artist" }
			},
			{ path = item.path, dir = "/music", name = "song.flac", ext = "flac" },
			nil
		)
	end
	lib:finish()
	return lib
end

--- A tags.json as version 1 wrote it: every track by path, in one tag.
---@param tracks { path: string, rating: number, count: number, last: number }[]
local function writeV1(tracks)
	local assignments = {}
	local ratings = {}
	local metrics = { tracks = {}, albums = {}, tags = {}, playlists = {} }
	for _, track in ipairs(tracks) do
		assignments[#assignments + 1] = { path = track.path, tags = { 1 } }
		ratings[#ratings + 1] = { path = track.path, value = track.rating }
		metrics.tracks[#metrics.tracks + 1] = { key = track.path, count = track.count, last = track.last }
	end

	local data = {
		version = 1,
		tags = { { id = 1, name = "Keep", hidden = false } },
		assignments = assignments,
		playlists = {},
		metrics = metrics,
		ratings = ratings,
		albumRatings = {}
	}
	assert(fs.write(paths.file("tags.json"), json.encode(data)))
end

test.it("adopts a version-1 file against the library the app loaded", function()
	clean()
	local path = "/music/a.flac"
	writeV1({ { path = path, rating = 4, count = 2, last = 50 } })

	local current = library({ { path = path, fingerprint = "0123456789abcdef" } })
	local libraries = libraryService(current)
	---@cast libraries beat.LibraryService
	local service = Collections.new({ library = libraries, toasts = toasts })
	local key = names.trackKey(current.tracks[1])

	test.equal(service.taxonomy:rating(key), 4, "the rating is on the audio now")
	test.truthy(service.taxonomy:isTagged(key, 1), "and so is the tag")
	test.equal(assert(service.taxonomy:trackMetric(current.tracks[1])).count, 2)
	test.equal(next(service.taxonomy.legacy.ratings), nil, "nothing is left waiting")

	local written = json.decode(assert(fs.read(paths.file("tags.json")))):unpack()
	test.equal(written.version, 2, "the adoption was written")
	test.equal(written.assignments[1].key, key)
	test.truthy(fs.exists(paths.file("tags.v1.json")), "the version-1 file is kept beside it")
end)

test.it("adopts entries a later library brings a path for", function()
	clean()
	local first, second = "/music/a.flac", "/music/b.flac"
	writeV1({
		{ path = first, rating = 4, count = 2, last = 50 },
		{ path = second, rating = 3, count = 1, last = 20 }
	})

	local firstLibrary = library({ { path = first, fingerprint = "aaaabbbbccccdddd" } })
	local libraries = libraryService(firstLibrary)
	---@cast libraries beat.LibraryService
	local service = Collections.new({ library = libraries, toasts = toasts })
	test.equal(service.taxonomy.legacy.ratings[second], 3, "the path no library holds waits")

	local secondLibrary = library({
		{ path = first, fingerprint = "aaaabbbbccccdddd" },
		{ path = second, fingerprint = "1111222233334444" }
	})
	libraries.finished:fire(secondLibrary)

	test.equal(service.taxonomy:rating(names.trackKey(secondLibrary.tracks[2])), 3, "the new library claims it")
	test.equal(next(service.taxonomy.legacy.ratings), nil)
end)
