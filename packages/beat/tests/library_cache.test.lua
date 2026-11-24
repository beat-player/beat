-- The cache is what the app draws from on a launch after a scan, so what it keeps has to come back
-- as the library the scan built: same albums, same artists. A file whose tags do not say which
-- album it belongs to -- a track credited "Kanye West, Jay-Z" in a folder of one album -- is the
-- case that only the scan's own answer can be right about.
local test = require("lde-test")
local paths = require("beat.paths")
local Library = require("beat.music.library")
local LibraryCache = require("beat.app.services.library.cache")
local LibraryService = require("beat.app.services.library.init")
local fs = require("fs")
local json = require("json")

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

--- Rewrites a saved cache's header to an earlier layout, keeping its records as they were.
---@param version number
local function rewriteVersion(version)
	local file = paths.file("library.json")
	local document = json.decode(assert(fs.read(file))):unpack()
	document.version = version
	assert(fs.write(file, json.encode(document)))
end

test.it("reads a version 6 cache that grouped every track the way 7 does", function()
	local library = Library.new(ROOT)
	local info, entry = file("01 - Heard Em Say", "Kanye West")
	-- 6 named a file with no album tag after its folder. This file's folder is not its album, so
	-- both versions group it the same, and reading its file again would only cost a round trip.
	entry.path = ROOT .. "/Kanye/01 - Heard Em Say.flac"
	entry.dir = ROOT .. "/Kanye"
	library:add(info, entry)
	library:finish()
	test.equal(LibraryCache.save(library), true)
	rewriteVersion(6)

	local loaded, outdated = LibraryCache.load(ROOT)
	assert(loaded, "a 6 cache that says what 7 would is still usable")
	test.equal(#loaded.tracks, 1)
	test.equal(#loaded.albums, 1)
	test.equal(loaded.albums[1].title, "Late Registration")
	test.equal(outdated, nil, "and it has nothing left to read")
	fs.delete(paths.file("library.json"))
end)

test.it("leaves a version 6 track that may have been named after its folder", function()
	local library = Library.new(ROOT)
	-- The helper files tracks beside their album's name, which is the case 6 may have made up for a
	-- file with no album tag; nothing in the record says whether the tag was there.
	library:add(file("01 - Heard Em Say", "Kanye West"))
	library:finish()
	test.equal(LibraryCache.save(library), true)
	rewriteVersion(6)

	local loaded, outdated = LibraryCache.load(ROOT)
	assert(loaded, "the records it can vouch for are still usable")
	test.equal(#loaded.tracks, 0, "the track it cannot vouch for is not in the library")
	assert(outdated, "and its file is handed back to be read")
	test.equal(outdated[1], ROOT .. "/Late Registration/01 - Heard Em Say.flac")
	fs.delete(paths.file("library.json"))
end)

test.it("leaves a version 6 track whose artist may have been named after its folder", function()
	local library = Library.new(ROOT)
	-- 6 named a file with no artist tag after the folder above its album's, which is what this
	-- record's artist says; 7 calls that an unknown artist, so the record cannot be trusted.
	library:add(file("01 - Heard Em Say", "music"))
	library:finish()
	test.equal(LibraryCache.save(library), true)
	rewriteVersion(6)

	local loaded, outdated = LibraryCache.load(ROOT)
	assert(loaded, "the records it can vouch for are still usable")
	test.equal(#loaded.tracks, 0, "the track it cannot vouch for is not in the library")
	assert(outdated, "and its file is handed back to be read")
	test.equal(outdated[1], ROOT .. "/Late Registration/01 - Heard Em Say.flac")
	fs.delete(paths.file("library.json"))
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

test.it("hands a scan records for the tracks a cache could vouch for", function()
	---@type table
	local deps = {
		settings = { values = { root = ROOT } },
		options = { scan = false },
		emit = function() end
	}
	---@cast deps { settings: beat.SettingsService, options: { scan: boolean? }, emit: fun(message: table) }
	local service = LibraryService.new(deps)
	local library = Library.new(ROOT)
	local info, entry = file("01 - Heard Em Say", "Kanye West")
	library:add(info, entry)
	library:finish()
	service.current = library

	service.outdated = nil
	local records = assert(service:records())
	test.equal(#records, 1, "a current library hands every track to the scan")
	test.equal(records[1].path, entry.path)
	test.equal(records[1].title, "01 - Heard Em Say")

	service.outdated = { entry.path }
	test.equal(#service:records(), 0, "a track an older cache could not vouch for is read again")
end)
