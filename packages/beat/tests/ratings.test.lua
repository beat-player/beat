-- A rating is a message like any click: whichever screen sends `rateTrack`, the collections
-- service rates the track and tags.json holds it before the next frame.
local test = require("lde-test")
local fs = require("fs")
local paths = require("beat.paths")
local Library = require("beat.music.library")
local TagStore = require("beat.app.services.collections.store")
local names = require("beat.music.names")
local App = require("beat.app")

-- The rating is written to tags.json, which must be a test's own and not the user's.
local configDirectory = os.tmpname() .. "-beat-ratings"
os.remove(configDirectory)
fs.mkdirAll(configDirectory)

local realDirectory = paths.directory
paths.directory = function() return configDirectory end

test.afterAll(function()
	paths.directory = realDirectory
	fs.rmdir(configDirectory)
end)

local function library()
	local lib = Library.new("/music")
	lib:add(
		{
			format = "FLAC",
			sampleRate = 44100,
			channels = 2,
			duration = 180,
			hasPicture = false,
			tags = { title = "A", artist = "artist", album = "album", albumArtist = "artist" }
		},
		{ path = "/music/a.flac", dir = "/music", name = "a.flac", ext = "flac" },
		nil
	)
	lib:finish()
	return lib
end

test.it("a rateTrack message rates the track and writes it to tags.json", function()
	App:init({ scan = false })
	local lib = library()
	App.services.library.current = lib
	local track = lib.tracks[1]
	local key = names.trackKey(track)

	App:act({ type = "rateTrack", id = track.id, stars = 4 })
	test.equal(App.services.collections.taxonomy:rating(key), 4)
	test.equal(TagStore.load():rating(key), 4, "tags.json holds it")

	App:act({ type = "rateTrack", id = track.id, stars = 0 })
	test.equal(TagStore.load():rating(key), 0, "and none takes it back on disk too")

	App.services.playback.player:close()
end)
