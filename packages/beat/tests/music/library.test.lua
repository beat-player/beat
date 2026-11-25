-- A track and an album keep only the fields a page reads for every row; the rest are held in the
-- library's columns and read back as fields. These tests are about that promise: every documented
-- field still reads, a value written back is kept, and a record dropped from the library takes its
-- columns with it rather than leaving a string behind.
local test = require("lde-test")
local Library = require("beat.music.library")

local ROOT = "/music"

---@param title string
---@param artist string
---@param track number
---@return table info
---@return table entry
local function file(title, artist, track)
	local name = string.format("%02d - %s", track, title)
	return {
		format = "FLAC",
		duration = 200,
		sampleRate = 44100,
		channels = 2,
		hasPicture = true,
		fingerprint = "fingerprint-" .. title,
		tags = { title = title, artist = artist, album = "Night Drive", track = track, genre = "Ambient", date = "2021" }
	}, {
		path = ROOT .. "/Night Drive/" .. name .. ".flac",
		dir = ROOT .. "/Night Drive",
		name = name .. ".flac",
		ext = "flac",
		modifyTime = 1600000000
	}
end

---@param library beat.Library
---@param at number
local function addTrack(library, at)
	local info, entry = file("Song " .. at, "Mira Vale", at)
	return library:add(info, entry)
end

test.it("reads every documented track field back", function()
	local library = Library.new(ROOT)
	addTrack(library, 1)
	library:finish()

	local track = library.tracks[1]
	test.equal(track.title, "Song 1")
	test.equal(track.artist, "Mira Vale")
	test.equal(track.album, "Night Drive")
	test.equal(track.albumArtist, "Mira Vale")
	test.equal(track.albumId, library.albums[1].id)
	test.equal(track.artistId, library.artists[1].id)
	test.equal(track.number, 1)
	test.equal(track.disc, 1)
	test.equal(track.year, 2021)
	test.equal(track.genre, "Ambient")
	test.equal(track.duration, 200)
	test.equal(track.format, "FLAC")
	test.equal(track.sampleRate, 44100)
	test.equal(track.channels, 2)
	test.equal(track.hasPicture, true)
	test.equal(track.modified, 1600000000)
	test.equal(track.fingerprint, "fingerprint-Song 1")
	test.equal(track.coverCache, nil)
end)

test.it("keeps a track to the fields its rows read, and answers the rest from a column", function()
	local library = Library.new(ROOT)
	addTrack(library, 1)
	library:finish()

	local own = 0
	for _ in pairs(library.tracks[1]) do own += 1 end
	test.equal(own, 8, "a track's own table holds what a row reads; the rest is a column")
	test.truthy(library.columns.fingerprint[library.tracks[1].id], "the fingerprint is in a column")
end)

test.it("computes an album's length and count from its tracks", function()
	local library = Library.new(ROOT)
	addTrack(library, 1)
	addTrack(library, 2)
	library:finish()

	local album = library.albums[1]
	test.equal(album.trackCount, 2)
	test.equal(album.duration, 400)
	test.equal(album.single, nil, "an album tag names an album, not a single")

	-- The values follow the track list they are read from, so a folder dropped from the library
	-- shortens the album it was part of without anything rebuilding a sum.
	library:removeUnder(ROOT .. "/Night Drive")
	local remained = library.albums[1]
	test.equal(remained == nil and 0 or remained.trackCount, 0)
end)

test.it("keeps a value written after the track was built", function()
	local library = Library.new(ROOT)
	addTrack(library, 1)
	library:finish()

	local album = library.albums[1]
	album.coverCache = "/tmp/cover.jpg"
	test.equal(album.coverCache, "/tmp/cover.jpg")

	local track = library.tracks[1]
	track.searchText = "song 1"
	test.equal(track.searchText, "song 1")
	test.equal(library.columns.searchText[track.id], "song 1")
end)

test.it("gives back a removed track's columns", function()
	local library = Library.new(ROOT)
	addTrack(library, 1)
	addTrack(library, 2)
	library:finish()
	local id = library.tracks[1].id

	test.equal(library:removeUnder(ROOT), true)
	test.equal(library.columns.fingerprint[id], nil, "the removed track's column value is gone")
	test.equal(#library.tracks, 0)
end)

test.it("folds the search text once and gives it back when the query empties", function()
	local library = Library.new(ROOT)
	addTrack(library, 1)
	library:finish()

	local albums, _, tracks = library:search("night")
	test.equal(#albums, 1)
	test.equal(#tracks, 1)
	test.equal(library.columns.searchText[library.tracks[1].id], "song 1 mira vale night drive")

	library:forgetSearch()
	test.equal(library.columns.searchText, nil, "an empty query keeps no folded text")
end)

---@param library beat.Library
---@param title string
---@param artist string
local function addNamed(library, title, artist)
	local info, entry = file(title, artist, #library.tracks + 1)
	info.tags.album = title .. " (Album)"
	entry.path = ROOT .. "/" .. artist .. "/" .. title .. ".flac"
	entry.dir = ROOT .. "/" .. artist
	entry.name = title .. ".flac"
	return library:add(info, entry)
end

---@param tracks beat.Track[]
---@return string[]
local function titles(tracks)
	local list = {}
	for at, track in ipairs(tracks) do list[at] = track.title end
	return list
end

test.it("finds a name without its accents, in any case and word order", function()
	local library = Library.new(ROOT)
	addNamed(library, "Over The Moon", "The Marías")
	addNamed(library, "Halo", "Beyoncé")
	addNamed(library, "Don't Stop Me Now", "Queen")
	library:finish()

	test.deepEqual(titles(select(3, library:search("marias"))), { "Over The Moon" })
	test.deepEqual(titles(select(3, library:search("the marias"))), { "Over The Moon" })
	test.deepEqual(titles(select(3, library:search("MARÍAS moon"))), { "Over The Moon" })
	test.deepEqual(titles(select(3, library:search("beyonce"))), { "Halo" })
	test.deepEqual(titles(select(3, library:search("dont stop"))), { "Don't Stop Me Now" })
	test.equal(#select(2, library:search("marías")), 1, "the artist is found too")
end)

test.it("finds a word typed with a typo, after the ones typed right", function()
	local library = Library.new(ROOT)
	addNamed(library, "Creep", "Radiohead")
	addNamed(library, "Radiohaed", "Somebody Else")
	addNamed(library, "Abc", "Xyz")
	library:finish()

	test.deepEqual(titles(select(3, library:search("radiohead"))), { "Creep", "Radiohaed" }, "exact first, then the typo")
	test.deepEqual(titles(select(3, library:search("radioheda"))), { "Creep", "Radiohaed" })
	test.deepEqual(titles(select(3, library:search("rdiohead"))), { "Creep", "Radiohaed" })
	test.equal(#select(3, library:search("abd")), 0, "a short word is only found as typed")
	test.equal(#select(3, library:search("zzzzzzzz")), 0)
end)
