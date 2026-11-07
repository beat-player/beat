local test = require("lde-test")
local fs = require("fs")
local path = require("path")
local Scanner = require("beat.music.scan")

local HERE = (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".")
local FIXTURES = path.join(HERE, "..", "fixtures")
local TONE = FIXTURES .. "/tone.wav"
local TAGGED = FIXTURES .. "/tagged.flac"
local COVER = FIXTURES .. "/cover.png"

local function tempDir()
	local dir = os.tmpname() .. "-beat-scan"
	fs.mkdirAll(dir)
	assert(fs.isdir(dir))
	return dir
end

local function copy(from, to)
	assert(fs.copy(from, to))
end

local function scanAll(root)
	local scanner = Scanner.new(root)
	local rounds = 0

	while not scanner:isDone() do
		scanner:step(0.05, os.clock)
		rounds = rounds + 1
		test.less(rounds, 10000, "the scan finished")
	end

	return scanner
end

local function removeTree(root)
	local iterator = fs.readdir(root)
	if iterator ~= nil then
		for entry in iterator do
				local child = path.join(root, entry.name)
				if entry.type == "dir" then
					removeTree(child)
				else
					fs.delete(child)
				end
			end
	end
	fs.rmdir(root)
end

---@param library beat.Library
---@param title string
local function albumNamed(library, title)
	for _, album in ipairs(library.albums) do
			if album.title == title then return album end
		end
	error("no album named " .. title)
end

test.it("enumerates a tree without inspecting the files", function()
	local root = tempDir()
	local first = path.join(root, "Artist", "Album")
	local second = path.join(root, "Other")
	fs.mkdirAll(first)
	fs.mkdirAll(second)
	copy(TONE, path.join(first, "01 tone.wav"))
	copy(TAGGED, path.join(first, "02 tagged.flac"))
	copy(TONE, path.join(second, "03 tone.wav"))
	copy(COVER, path.join(first, "cover.png"))

	local scanner = Scanner.new(root)
	local rounds = 0
	while scanner.phase == "enumerate" do
		scanner:enumerateStep(0.05, os.clock)
		rounds = rounds + 1
		test.less(rounds, 10000, "the walk finished")
	end

	---@type { path: string, cover: string? }[]
	local entries = scanner:entries()
	test.equal(#entries, 3, "every audio file is in the manifest")
	test.equal(scanner.trackCount, 0, "nothing was inspected")

	local covered = false
	for _, entry in ipairs(entries) do
			if entry.path == path.join(first, "01 tone.wav") then
				test.equal(entry.cover, path.join(first, "cover.png"))
				covered = true
			end
		end
	test.truthy(covered, "the folder cover is carried in the manifest")

	removeTree(root)
end)

test.it("scans folders, groups albums, reads the cover beside them", function()
	local root = tempDir()
	local albumDir = path.join(root, "Mira Vale", "Night Drive")
	fs.mkdirAll(albumDir)
	assert(fs.isdir(albumDir))
	copy(TONE, path.join(albumDir, "01 Night Drive.wav"))
	copy(TONE, path.join(albumDir, "02 Afterglow.wav"))
	copy(COVER, path.join(albumDir, "cover.png"))

	local otherDir = path.join(root, "Various", "Compilation")
	fs.mkdirAll(otherDir)
	assert(fs.isdir(otherDir))
	copy(TONE, path.join(otherDir, "03 Guest.wav"))
	copy(TAGGED, path.join(otherDir, "04 Tagged.flac"))

	local hidden = path.join(root, ".hidden")
	fs.mkdirAll(hidden)
	assert(fs.isdir(hidden))
	copy(TONE, path.join(hidden, "secret.wav"))
	fs.write(path.join(root, "notes.txt"), "not music")

	local scanner = scanAll(root)
	local library = scanner.library

	test.equal(#library.tracks, 4, "four playable files")
	test.equal(#library.albums, 3, "the tagged file is its own album")
	test.equal(scanner:progress().phase, "done")
	test.truthy(library.ready)

	local night = albumNamed(library, "Night Drive")
	test.truthy(night, "the folder's tracks are one album")
	test.equal(#night.tracks, 2)
	test.equal(night.tracks[1].title, "Night Drive", "the track number is stripped from the name")
	test.equal(night.tracks[2].title, "Afterglow")
	test.equal(night.coverPath, path.join(albumDir, "cover.png"))
	test.equal(night.artist, "Mira Vale")

	local tagged = albumNamed(library, "Flac Album")
	test.truthy(tagged)
	test.equal(tagged.tracks[1].title, "Flac Title")
	test.truthy(tagged.tracks[1].hasPicture)

	test.equal(#library:recentlyAdded(2), 2, "the newest albums are the scan's own order")
	test.falsy(library.tracks[1].path:find("/.hidden/", 1, true), "hidden folders are skipped")

	removeTree(root)
end)

test.it("scans without building the worker a second library", function()
	local root = tempDir()
	copy(TONE, path.join(root, "one.wav"))

	local seen = 0
	local scanner = Scanner.new(root, { library = false})
	scanner.onTrack = function() seen = seen + 1 end

	while not scanner:isDone() do
		scanner:step(0.05, os.clock)
	end

	test.falsy(scanner.library, "the worker does not keep every track twice")
	test.equal(seen, 1, "it still reports every inspected track")
	test.equal(scanner:progress().tracks, 1)

	removeTree(root)
end)

test.it("cancels without finishing the library", function()
	local root = tempDir()
	copy(TONE, path.join(root, "one.wav"))

	local scanner = Scanner.new(root)
	scanner:cancel()
	test.truthy(scanner:isDone())
	test.equal(scanner:progress().phase, "cancelled")
	test.falsy(scanner:step(0.1, os.clock))

	removeTree(root)
end)

test.it("reports a corrupt file and keeps scanning", function()
	local root = tempDir()
	fs.write(path.join(root, "broken.flac"), "not a flac")
	copy(TONE, path.join(root, "good.wav"))

	local scanner = scanAll(root)
	test.equal(#scanner.library.tracks, 1)
	test.equal(scanner.skipped, 1)
	test.equal(#scanner.errors, 1)
	test.includes(scanner.errors[1].path, "broken.flac")

	removeTree(root)
end)

local function listing(root, prefix, into)
	prefix = prefix or ""
	into = into or {}
	local iterator = fs.readdir(root)
	if iterator == nil then return into end
	for entry in iterator do
			local name = prefix .. entry.name
			if entry.type == "dir" then
				listing(path.join(root, entry.name), name .. "/", into)
			else
				into[#into + 1] = name
			end
		end
	return into
end

test.it("writes nothing into the library it scans", function()
	local root = tempDir()
	local dir = path.join(root, "Mira Vale", "Night Drive")
	fs.mkdirAll(dir)
	assert(fs.isdir(dir))
	copy(TONE, path.join(dir, "01 Night Drive.wav"))

	local before = listing(root)
	table.sort(before)
	scanAll(root)
	local after = listing(root)
	table.sort(after)

	test.equal(#after, #before)
	for at, name in ipairs(before) do test.equal(after[at], name) end

	removeTree(root)
end)

test.it("searches titles, albums and artists", function()
	local root = tempDir()
	local dir = path.join(root, "Mira Vale", "Night Drive")
	fs.mkdirAll(dir)
	assert(fs.isdir(dir))
	copy(TONE, path.join(dir, "01 Night Drive.wav"))

	local library = scanAll(root).library
	local albums, _, tracks = library:search("night")

	test.equal(#albums, 1)
	test.equal(#tracks, 1)
	test.equal(albums[1].title, "Night Drive")
	test.equal(tracks[1].title, "Night Drive")

	local _, foundArtists = library:search("mira")
	test.equal(#foundArtists, 1)
	test.equal(foundArtists[1].name, "Mira Vale")
	test.equal(albums[1].artistId, foundArtists[1].id)
	test.equal(tracks[1].artistId, foundArtists[1].id)

	local none = library:search("nothing here")
	test.equal(#none, 0)

	removeTree(root)
end)
