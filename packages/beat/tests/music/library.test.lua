-- A track and an album keep only the fields a page reads for every row; the rest are held in the
-- library's columns and read back as fields. These tests are about that promise: every documented
-- field still reads, a value written back is kept, and a record dropped from the library takes its
-- columns with it rather than leaving a string behind.
local test = require("lde-test")
local Library = require("beat.music.library")
local names = require("beat.music.names")

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

--- Adds one track under its own album and artist, picked so that neither the album order nor the
--- track order inside an album is the order the files were added in -- and so that folding changes
--- the order too.
---@param library beat.Library
---@param at number
local function addShaped(library, at)
	local titles = { "Zulu", "Alpha", "Mike", "Bravo", "Yankee", "Charlie", "Delta", "Echo" }
	local artists = { "Zed", "Amy", "Zed", "Émile", "Aster", "Aster", "Amy", "Émile" }
	local albums = { "Same Album", "Alpha Album", "Same Album", "Bravo Album", "Same Album", "Alpha Album", "Bravo Album", "Émile Album" }
	local title, artist, album = titles[at], artists[at], albums[at]
	local info, entry = file(title, artist, (at * 7) % 5 + 1)
	info.tags.album = album
	info.tags.albumArtist = artist
	entry.path = string.format("%s/%s/%s/%02d.flac", ROOT, artist, album, 9 - at)
	entry.dir = string.format("%s/%s/%s", ROOT, artist, album)
	entry.name = string.format("%02d.flac", 9 - at)
	return library:add(info, entry, "/covers/" .. album .. ".jpg")
end

--- What a closed library holds, by names and paths rather than record identity: two libraries
--- built from the same tracks hold different objects and ids.
---@param library beat.Library
---@return table
local function closedShape(library)
	local albums = {}
	for at, album in ipairs(library.albums) do
		local tracks = {}
		for index, track in ipairs(album.tracks) do tracks[index] = track.path end
		albums[at] = {
			key = album.key,
			tracks = tracks,
			coverTrack = album.coverTrack and album.coverTrack.path,
			coverPath = album.coverPath
		}
	end
	local artists = {}
	for at, artist in ipairs(library.artists) do
		local names = {}
		for index, album in ipairs(artist.albums) do names[index] = album.key end
		artists[at] = { name = artist.name, albums = names, tracks = #artist.tracks }
	end
	return { albums = albums, artists = artists }
end

test.it("sorts in slices to what one finish gives", function()
	local whole = Library.new(ROOT)
	local sliced = Library.new(ROOT)
	for at = 1, 8 do
		addShaped(whole, at)
		addShaped(sliced, at)
	end

	whole:finish()
	local slices = 0
	while not sliced:finishStep(0) do
		slices += 1
		assert(slices < 1000, "the sliced sort finishes")
	end

	test.truthy(slices > 1, "the sort took more than one slice")
	test.deepEqual(closedShape(sliced), closedShape(whole))
	test.truthy(sliced.ready)
	test.equal(sliced.finishing, nil, "nothing is left of the sort")
	test.equal(next(sliced.strings), nil, "the interning table is let go when the sort closes")
end)

test.it("drops a sliced sort a track arrives in the middle of, then closes it again", function()
	local library = Library.new(ROOT)
	for at = 1, 4 do addShaped(library, at) end
	test.equal(library:finishStep(0), false, "the sort ran out of its slice")

	addShaped(library, 5)
	test.equal(library.finishing, nil, "the partial sort is dropped rather than finished inside the add")
	test.equal(library.ready, false, "and the library is open again")
	test.equal(#library.tracks, 5, "the added track is in")
	library:finish()

	local last = nil
	for _, album in ipairs(library.albums) do
		local folded = names.fold(album.title)
		if last ~= nil then test.truthy(folded >= last, "the albums are in order") end
		last = folded
	end
	test.equal(library.finishing, nil)
end)
