-- The cache is what the app draws from on a launch after a scan, so what it keeps has to come back
-- as the library the scan built: same albums, same artists. A file whose tags do not say which
-- album it belongs to -- a track credited "Kanye West, Jay-Z" in a folder of one album -- is the
-- case that only the scan's own answer can be right about.
local test = require("lde-test")
local paths = require("beat.paths")
local Library = require("beat.music.library")
local LibraryCache = require("beat.app.services.library.cache")
local fs = require("fs")

local configDirectory = os.tmpname() .. "-beat-cache-config"
os.remove(configDirectory)
fs.mkdirAll(configDirectory)

local realDirectory = paths.directory
paths.directory = function() return configDirectory end

test.afterAll(function()
	paths.directory = realDirectory
	fs.rmdir(configDirectory)
end)

local ROOT = "/music"

---@param name string
---@param artist string
---@return table info
---@return table entry
local function file(name, artist)
	return {
		format = "FLAC",
		duration = 200,
		sampleRate = 44100,
		channels = 2,
		hasPicture = false,
		tags = { title = name, artist = artist, album = "Late Registration" }
	}, {
		path = ROOT .. "/Late Registration/" .. name .. ".flac",
		dir = ROOT .. "/Late Registration",
		name = name .. ".flac",
		ext = "flac",
		modifyTime = 0
	}
end

test.it("loads a scan's albums back as the scan made them", function()
	local library = Library.new(ROOT)
	library:add(file("01 - Heard Em Say", "Kanye West, Adam Levine"))
	library:add(file("02 - Gold Digger", "Kanye West, Jamie Foxx"))
	library:add(file("03 - Touch The Sky", "Kanye West, Lupe Fiasco"))
	library:add(file("04 - Drive Slow", "Kanye West, Paul Wall, GLC"))
	library:finish()

	test.equal(#library.albums, 1, "one album, because the folder is one: no track names an album artist")
	local scanned = library.albums[1]
	local scannedArtists = #library.artists

	test.equal(LibraryCache.save(library), true)

	local loaded = assert(LibraryCache.load(ROOT), "the cache it just wrote")

	test.equal(#loaded.albums, 1, "and one album again after a launch")
	test.equal(loaded.albums[1].title, scanned.title)
	test.equal(loaded.albums[1].artist, scanned.artist, "with the artist the scan gave it, not the featured one")
	test.equal(#loaded.albums[1].tracks, 4)
	test.equal(#loaded.tracks, 4)

	-- The artists a scan makes are what it is faithful to, whatever they are: a credit in the artist
	-- field is a profile of its own in the library, and the cache brings back the same ones.
	test.equal(#loaded.artists, scannedArtists, "as many artists as the scan made")
end)

test.it("keeps an album an album-artist tag names, across folders", function()
	local library = Library.new(ROOT)
	for _, disc in ipairs({ "CD1", "CD2" }) do
		local info = { format = "FLAC", duration = 100, sampleRate = 44100, channels = 2, hasPicture = false, tags = { title = disc .. " one", artist = "Kanye West", album = "Late Registration", albumArtist = "Kanye West" } }
		library:add(info, { path = ROOT .. "/" .. disc .. "/one.flac", dir = ROOT .. "/" .. disc, name = "one.flac", ext = "flac", modifyTime = 0 })
	end
	library:finish()

	test.equal(#library.albums, 1, "one album, named by its album artist and title")
	test.equal(LibraryCache.save(library), true)

	local loaded = assert(LibraryCache.load(ROOT))
	test.equal(#loaded.albums, 1, "and one album after a launch, though its files are in two folders")
	test.equal(#loaded.albums[1].tracks, 2)
end)

test.it("ignores a cache written for another version of the cache", function()
	local path = paths.file("library.json")
	assert(fs.write(path, '{"version":3,"root":"' .. ROOT .. '","tracks":[]}'))
	test.equal(LibraryCache.load(ROOT), nil, "an older cache is dropped rather than guessed at")
	fs.delete(path)
end)

test.it("keeps each track's fingerprint, so tags stay attached across a launch", function()
	local library = Library.new(ROOT)
	local info, entry = file("01 - Heard Em Say", "Kanye West")
	info.fingerprint = "0123456789abcdef"
	library:add(info, entry)
	library:finish()
	test.equal(LibraryCache.save(library), true)

	local loaded = assert(LibraryCache.load(ROOT))
	test.equal(loaded.tracks[1].fingerprint, "0123456789abcdef")
end)
