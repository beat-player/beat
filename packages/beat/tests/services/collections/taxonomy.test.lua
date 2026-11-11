local test = require("lde-test")
local fs = require("fs")
local json = require("json")
local paths = require("beat.paths")
local Library = require("beat.music.library")
local Taxonomy = require("beat.app.services.collections.taxonomy")
local TagStore = require("beat.app.services.collections.store")
local names = require("beat.music.names")

-- The tags.json these tests read and write must be their own and not the user's.
local configDirectory = os.tmpname() .. "-beat-taxonomy"
os.remove(configDirectory)
fs.mkdirAll(configDirectory)

test.afterAll(function() fs.rmdir(configDirectory) end)

---@param name string
local function freshDir(name)
	local dir = paths.file(name, configDirectory)
	fs.mkdirAll(dir)
	return dir
end

--- A real library, so what these tests hand `playlistTracks` and `recordListen` is what the app
--- hands them: three tracks in one album, with no fingerprint, as a scan that cannot compute one.
local function library()
	local lib = Library.new("/music")
	for _, name in ipairs({ "a", "b", "c" }) do
		lib:add(
			{
				format = "FLAC",
				sampleRate = 44100,
				channels = 2,
				duration = 180,
				hasPicture = false,
				tags = { title = name:upper(), artist = "artist", album = "album", albumArtist = "artist" }
			},
			{ path = "/music/" .. name .. ".flac", dir = "/music", name = name .. ".flac", ext = "flac" },
			nil
		)
	end
	lib:finish()
	return lib
end

--- A library of one track. The fingerprint is what the audio is; the path is where this copy
--- happens to be, and a scan that computes no fingerprint leaves it nil.
---@param root string
---@param file string
---@param fingerprint string?
---@param title string?
local function solo(root, file, fingerprint, title)
	local lib = Library.new(root)
	lib:add(
		{
			format = "FLAC",
			sampleRate = 44100,
			channels = 2,
			duration = 180,
			hasPicture = false,
			fingerprint = fingerprint,
			tags = { title = title or "Song", artist = "artist", album = "album", albumArtist = "artist" }
		},
		{ path = file, dir = root, name = "song.flac", ext = "flac" },
		nil
	)
	lib:finish()
	return lib
end

---@param dir string
---@param data table
local function writeStore(dir, data)
	local file = paths.file("tags.json", dir)
	assert(fs.write(file, json.encode(data)))
	return file
end

--- A tags.json as version 1 wrote it, with one entry per argument.
---@param dir string
---@param tracks { path: string, tags: number[]?, rating: number?, count: number?, last: number? }[]
---@param tags { id: number, name: string, hidden: boolean? }[]
local function writeV1(dir, tracks, tags)
	local assignments = {}
	local ratings = {}
	local metrics = { tracks = {}, albums = {}, tags = {}, playlists = {} }
	for _, track in ipairs(tracks) do
		if track.tags ~= nil then assignments[#assignments + 1] = { path = track.path, tags = track.tags } end
		if track.rating ~= nil then ratings[#ratings + 1] = { path = track.path, value = track.rating } end
		if track.count ~= nil then
			metrics.tracks[#metrics.tracks + 1] = { key = track.path, count = track.count, last = track.last or 0 }
		end
	end

	return writeStore(
		dir,
		{
			version = 1,
			tags = tags,
			assignments = assignments,
			playlists = {},
			metrics = metrics,
			ratings = ratings,
			albumRatings = {}
		}
	)
end

test.it("names tags case-insensitively and toggles them on a track", function()
	local taxonomy = Taxonomy.new()
	local lib = library()
	local key = names.trackKey(lib.tracks[1])
	local high = taxonomy:addTag("  High Energy ")
	local late = taxonomy:addTag("Late Night")

	test.truthy(high and late)
	test.equal(high.name, "High Energy")
	test.falsy(taxonomy:addTag("high energy"), "a tag name is one name regardless of case")
	test.equal(#taxonomy:visibleTags(), 2)

	test.truthy(taxonomy:toggleTag(key, high.id))
	test.truthy(taxonomy:isTagged(key, high.id))
	test.falsy(taxonomy:isTagged(key, late.id))
	test.equal(high.count, 1)
	test.falsy(taxonomy:toggleTag(key, high.id))
	test.equal(high.count, 0)
end)

test.it("filters a smart playlist by all or any of its tags", function()
	local taxonomy = Taxonomy.new()
	local high = assert(taxonomy:addTag("High Energy"))
	local late = assert(taxonomy:addTag("Late Night"))
	local lib = library()
	local a, b = names.trackKey(lib.tracks[1]), names.trackKey(lib.tracks[2])

	taxonomy:setTag(a, high.id, true)
	taxonomy:setTag(a, late.id, true)
	taxonomy:setTag(b, high.id, true)

	local all = assert(taxonomy:addPlaylist("Both", true, { high.id, late.id }, "all"))
	local any = assert(taxonomy:addPlaylist("Either", true, { high.id, late.id }, "any"))
	local allTracks = taxonomy:playlistTracks(all, lib)
	local anyTracks = taxonomy:playlistTracks(any, lib)

	test.equal(#allTracks, 1)
	test.equal(allTracks[1].path, "/music/a.flac")
	test.equal(#anyTracks, 2)
end)

test.it("keeps manual playlist membership in a hidden tag", function()
	local taxonomy = Taxonomy.new()
	local lib = library()
	local key = names.trackKey(lib.tracks[3])
	local playlist = assert(taxonomy:addPlaylist("Favourites", false))

	taxonomy:setPlaylistTrack(playlist, key, true)
	local manualTracks = taxonomy:playlistTracks(playlist, lib)
	test.equal(#manualTracks, 1)
	test.equal(manualTracks[1].path, "/music/c.flac")
	test.equal(#taxonomy:visibleTags(), 0, "the manual membership tag stays out of the visible list")
	test.truthy(playlist.hiddenTagId ~= nil)

	taxonomy:setPlaylistTrack(playlist, key, false)
	test.equal(#taxonomy:playlistTracks(playlist, lib), 0)
end)

test.it("round-trips tags and playlists through its packed form", function()
	local taxonomy = Taxonomy.new()
	local lib = library()
	local high = assert(taxonomy:addTag("High Energy"))
	local smart = assert(taxonomy:addPlaylist("High", true, { high.id }, "all"))
	local manual = assert(taxonomy:addPlaylist("Manual", false))
	taxonomy:setTag(names.trackKey(lib.tracks[1]), high.id, true)
	taxonomy:setPlaylistTrack(manual, names.trackKey(lib.tracks[2]), true)

	local loaded = Taxonomy.unpack(taxonomy:pack())
	test.equal(#loaded:visibleTags(), 1)
	test.equal(loaded:visibleTags()[1].name, "High Energy")
	test.equal(#loaded:playlistTracks(assert(loaded:playlist(smart.id)), lib), 1)
	test.equal(#loaded:playlistTracks(assert(loaded:playlist(manual.id)), lib), 1)
	local reloadedManual = assert(loaded:playlist(manual.id))
	test.truthy(loaded.tagById[assert(reloadedManual.hiddenTagId)].hidden)
end)

test.it("makes an automatic smart playlist for each tag", function()
	local taxonomy = Taxonomy.new()
	local tag = assert(taxonomy:addTag("Focus"))
	local playlists = taxonomy.playlists
	test.equal(#playlists, 1)
	test.equal(playlists[1].name, "Focus")
	test.equal(playlists[1].autoTagId, tag.id)
	test.truthy(playlists[1].smart)
	test.falsy(playlists[1].manual)
	test.equal(tag.playlistId, playlists[1].id)
end)

test.it("mixes smart criteria and hand-added tracks in one playlist", function()
	local taxonomy = Taxonomy.new()
	local tag = assert(taxonomy:addTag("Focus"))
	local playlist = taxonomy.playlists[1]
	local lib = library()
	taxonomy:setTag(names.trackKey(lib.tracks[1]), tag.id, true)
	taxonomy:setPlaylistTrack(playlist, names.trackKey(lib.tracks[2]), true)

	local tracks = taxonomy:playlistTracks(playlist, lib)
	test.equal(#tracks, 2, "both the tag match and the hand-added track are in the playlist")
	test.truthy(playlist.manual)
	test.truthy(playlist.smart)
end)

test.it("renames a tag by id and removes it with its automatic playlist", function()
	local taxonomy = Taxonomy.new()
	local tag = assert(taxonomy:addTag("Focus"))
	local auto = taxonomy.playlists[1]
	local renamed = assert(taxonomy:renameTag(tag.id, "Deep Focus"))
	test.equal(renamed.id, tag.id)
	test.equal(taxonomy.tagById[tag.id].name, "Deep Focus")
	test.equal(auto.name, "Deep Focus")

	taxonomy:removeTag(tag.id)
	test.equal(taxonomy.tagById[tag.id], nil)
	test.equal(taxonomy:playlist(auto.id), nil, "the automatic playlist goes with the tag")
end)

test.it("records listens for tracks, albums, tags and playlists", function()
	local taxonomy = Taxonomy.new()
	local tag = assert(taxonomy:addTag("Focus"))
	local auto = taxonomy.playlists[1]
	local lib = library()
	local key = names.trackKey(lib.tracks[1])
	taxonomy:setTag(key, tag.id, true)

	taxonomy:recordListen(lib.tracks[1], lib, auto.id, 1234)
	test.equal(taxonomy.metrics.tracks[key].count, 1)
	test.equal(taxonomy.metrics.albums["artist\0album"].count, 1)
	test.equal(taxonomy.metrics.tags[tag.id].count, 1)
	test.equal(taxonomy.metrics.playlists[auto.id].count, 1)
	local recent = taxonomy:recentAlbums(lib, 5)
	test.equal(#recent, 1)
	test.equal(recent[1].key, "artist\0album")

	local loaded = Taxonomy.unpack(taxonomy:pack())
	test.equal(loaded.metrics.tracks[key].count, 1)
	test.equal(loaded.metrics.albums["artist\0album"].last, 1234)
end)

test.it("rates a track from one to five stars, and none takes the rating away", function()
	local taxonomy = Taxonomy.new()
	local lib = library()
	local key = names.trackKey(lib.tracks[1])
	test.equal(taxonomy:rating(key), 0, "an unrated track has none")

	taxonomy:setRating(key, 4)
	test.equal(taxonomy:rating(key), 4)
	taxonomy:setRating(key, 9)
	test.equal(taxonomy:rating(key), 5, "more than five is five")
	taxonomy:setRating(key, 3.7)
	test.equal(taxonomy:rating(key), 3, "part of a star is not a star")
	taxonomy:setRating(key, 0)
	test.equal(taxonomy:rating(key), 0)
	test.equal(taxonomy.ratings[key], nil, "an unrated track is not kept")
end)

test.it("keeps ratings through its packed form, and reads a file from before ratings", function()
	local taxonomy = Taxonomy.new()
	local lib = library()
	local a, b, c = names.trackKey(lib.tracks[1]), names.trackKey(lib.tracks[2]), names.trackKey(lib.tracks[3])
	local tag = assert(taxonomy:addTag("Chill"))
	taxonomy:setTag(a, tag.id, true)
	taxonomy:setRating(a, 5)
	taxonomy:setRating(b, 2)

	local loaded = Taxonomy.unpack(taxonomy:pack())
	test.equal(loaded:rating(a), 5)
	test.equal(loaded:rating(b), 2)

	-- tags.json as every version before ratings wrote it: everything else must still load.
	local older = taxonomy:pack()
	older.ratings = nil
	local fromOlder = Taxonomy.unpack(older)
	test.truthy(fromOlder:isTagged(a, tag.id), "the tags still load")
	test.equal(fromOlder:rating(a), 0)

	local edited = taxonomy:pack()
	edited.ratings = { { key = c, value = 12 } }
	test.equal(Taxonomy.unpack(edited):rating(c), 5, "a hand-edited file is held to five")
end)

test.it("keeps tags, rating, plays and playlist membership when a track moves", function()
	local taxonomy = Taxonomy.new()
	local tag = assert(taxonomy:addTag("Keep"))
	local playlist = assert(taxonomy:addPlaylist("Manual", false))

	local before = solo("/music", "/music/a.flac", "0011223344556677", "A")
	local track = before.tracks[1]
	local key = names.trackKey(track)
	taxonomy:setTag(key, tag.id, true)
	taxonomy:setRating(key, 4)
	taxonomy:recordListen(track, before, nil, 1000)
	taxonomy:setPlaylistTrack(playlist, key, true)

	local after = solo("/elsewhere", "/elsewhere/renamed.flac", "0011223344556677", "A")
	local moved = after.tracks[1]
	test.equal(names.trackKey(moved), key, "the identity is the audio, not the path")
	test.truthy(taxonomy:isTagged(key, tag.id), "the tag follows the file")
	test.equal(taxonomy:rating(key), 4, "and so does the rating")
	test.equal(assert(taxonomy:trackMetric(moved)).count, 1, "and the play count")
	test.equal(#taxonomy:playlistTracks(playlist, after), 1, "and the hand-added playlist membership")
	test.equal(taxonomy:playlistTracks(playlist, after)[1].path, "/elsewhere/renamed.flac")
end)

test.it("keeps them when the same audio is retagged", function()
	local taxonomy = Taxonomy.new()
	local tag = assert(taxonomy:addTag("Keep"))
	local before = solo("/music", "/music/a.flac", "0011223344556677", "Old Title")
	local key = names.trackKey(before.tracks[1])
	taxonomy:setTag(key, tag.id, true)
	taxonomy:setRating(key, 5)

	local after = solo("/music", "/music/a.flac", "0011223344556677", "A New Title")
	test.equal(after.tracks[1].title, "A New Title")
	test.equal(names.trackKey(after.tracks[1]), key, "a title is not part of the identity")
	test.truthy(taxonomy:isTagged(key, tag.id))
	test.equal(taxonomy:rating(key), 5)
end)

test.it("keys a track without a fingerprint by its path, as before", function()
	local lib = library()
	local track = lib.tracks[1]
	local key = names.trackKey(track)
	test.equal(key, "path:/music/a.flac")

	local taxonomy = Taxonomy.new()
	local tag = assert(taxonomy:addTag("Path"))
	taxonomy:setTag(key, tag.id, true)
	taxonomy:setRating(key, 5)
	taxonomy:recordListen(track, lib, nil, 100)
	test.truthy(taxonomy:isTagged(key, tag.id))
	test.equal(taxonomy:rating(key), 5)
	test.equal(assert(taxonomy:trackMetric(track)).count, 1)

	local loaded = Taxonomy.unpack(taxonomy:pack())
	test.truthy(loaded:isTagged("path:/music/a.flac", tag.id), "the path key round-trips")

	local moved = solo("/elsewhere", "/elsewhere/a.flac", nil)
	test.equal(taxonomy:rating(names.trackKey(moved.tracks[1])), 0, "with no audio identity a move is another track")
end)

test.it("reads a version-1 file into legacy, adopts it and writes version 2 with a backup", function()
	local dir = freshDir("adopt")
	local path = "/old/a.flac"
	local v1 = writeV1(dir, { { path = path, tags = { 1, 2 }, rating = 3, count = 2, last = 50 } }, {
		{ id = 1, name = "High Energy", hidden = false },
		{ id = 2, name = "__playlist_1", hidden = true }
	})
	local data = json.decode(assert(fs.read(v1))):unpack()
	data.playlists = {
		{ id = 1, name = "Mix", smart = false, tagIds = {}, match = "all", manual = true, hiddenTagId = 2, updatedAt = 0 }
	}
	writeStore(dir, data)

	local taxonomy = TagStore.load(dir)
	test.truthy(taxonomy.legacy.byPath[path] ~= nil, "a version-1 tag set is kept by path")
	test.equal(taxonomy.legacy.ratings[path], 3)
	test.equal(taxonomy.legacy.metrics[path].count, 2)
	test.equal(next(taxonomy.byKey), nil, "nothing is keyed by audio yet")

	local lib = solo("/library", path, "0123456789abcdef")
	local track = lib.tracks[1]
	local key = names.trackKey(track)
	test.equal(key, "0123456789abcdef")
	test.truthy(taxonomy:adopt(lib), "the path the library holds is claimed")
	test.equal(next(taxonomy.legacy.byPath), nil)
	test.equal(taxonomy.legacy.ratings[path], nil)
	test.equal(taxonomy.legacy.metrics[path], nil)
	test.truthy(taxonomy:isTagged(key, 1))
	test.truthy(taxonomy:isTagged(key, 2), "the hidden playlist tag moves with the rest")
	test.equal(taxonomy:rating(key), 3)
	test.equal(assert(taxonomy:trackMetric(track)).count, 2)
	test.equal(#taxonomy:playlistTracks(assert(taxonomy:playlist(1)), lib), 1, "and membership comes back")

	test.equal(TagStore.save(taxonomy, dir), true)

	local written = json.decode(assert(fs.read(paths.file("tags.json", dir)))):unpack()
	test.equal(written.version, 2)
	test.equal(#written.assignments, 1)
	test.equal(written.assignments[1].key, key, "the file is keyed by audio now")
	test.equal(written.ratings[1].key, key)
	test.equal(written.metrics.tracks[1].key, key)

	local backup = json.decode(assert(fs.read(paths.file("tags.v1.json", dir)))):unpack()
	test.equal(backup.version, 1, "the version-1 file is kept beside the new one")
	test.equal(backup.assignments[1].path, path)

	-- A version-1 file appearing again never replaces the copy that is already there.
	fs.write(paths.file("tags.v1.json", dir), "the original")
	writeStore(dir, data)
	test.equal(TagStore.save(taxonomy, dir), true, "the second write still succeeds")
	test.equal(fs.read(paths.file("tags.v1.json", dir)), "the original", "the first backup is never overwritten")
end)

test.it("keeps legacy entries for paths no library has, across saves and loads", function()
	local dir = freshDir("unadopted")
	local path = "/gone/a.flac"
	writeV1(dir, { { path = path, tags = { 1 }, rating = 4, count = 7, last = 90 } }, {
		{ id = 1, name = "Keep", hidden = false }
	})

	local taxonomy = TagStore.load(dir)
	local elsewhere = solo("/library", "/other/b.flac", "fedcba9876543210")
	test.falsy(taxonomy:adopt(elsewhere), "a library without the path claims nothing")
	test.equal(taxonomy.legacy.ratings[path], 4, "the entry stays in memory")
	test.equal(TagStore.save(taxonomy, dir), true)

	local reloaded = TagStore.load(dir)
	test.equal(reloaded.legacy.ratings[path], 4, "and survives a version-2 save and load")
	test.truthy(reloaded.legacy.byPath[path] ~= nil)
	test.equal(reloaded.legacy.metrics[path].count, 7)

	local later = solo("/later", path, "aaaabbbbccccdddd")
	local key = names.trackKey(later.tracks[1])
	test.truthy(reloaded:adopt(later), "a later library with the path claims it")
	test.equal(reloaded:rating(key), 4)
	test.truthy(reloaded:isTagged(key, 1))
	test.equal(assert(reloaded:trackMetric(later.tracks[1])).count, 7)
	test.equal(next(reloaded.legacy.ratings), nil)
end)

test.it("merges two legacy paths that turn out to be one fingerprint", function()
	local dir = freshDir("merge")
	local first, second = "/old/a.flac", "/old/b.flac"
	writeV1(dir, {
		{ path = first, tags = { 1 }, rating = 2, count = 1, last = 10 },
		{ path = second, tags = { 2 }, rating = 4, count = 2, last = 5 }
	}, {
		{ id = 1, name = "One", hidden = false },
		{ id = 2, name = "Two", hidden = false }
	})

	local taxonomy = TagStore.load(dir)
	local lib = Library.new("/library")
	for _, file in ipairs({ first, second }) do
		lib:add(
			{
				format = "FLAC",
				sampleRate = 44100,
				channels = 2,
				duration = 180,
				hasPicture = false,
				fingerprint = "0000111122223333",
				tags = { title = file, artist = "artist", album = "album", albumArtist = "artist" }
			},
			{ path = file, dir = "/library", name = "song.flac", ext = "flac" },
			nil
		)
	end
	lib:finish()

	local key = names.trackKey(lib.tracks[1])
	test.equal(names.trackKey(lib.tracks[2]), key, "two copies of one audio share a key")
	test.truthy(taxonomy:adopt(lib))
	test.truthy(taxonomy:isTagged(key, 1))
	test.truthy(taxonomy:isTagged(key, 2), "a tag set is a union")
	test.equal(taxonomy:rating(key), 2, "the first path in sorted order has the rating")
	local metric = taxonomy:trackMetric(lib.tracks[1])
	test.equal(metric.count, 3, "play counts add")
	test.equal(metric.last, 10, "and the last play is the later one")
	test.equal(next(taxonomy.legacy.byPath), nil)
	test.equal(next(taxonomy.legacy.ratings), nil)
	test.equal(next(taxonomy.legacy.metrics), nil)
end)

-- A track filed under its path because the scan that read it computed no fingerprint must not be
-- stranded there when a later scan does compute one: that is every track scanned by a version of
-- the app whose audio reader had no fingerprints yet.
test.it("moves what was filed under a path to the fingerprint the track later gets", function()
	local before = solo("/music", "/music/a.flac", nil)
	local taxonomy = Taxonomy.new()
	local tag = assert(taxonomy:addTag("Kept"))
	local pathKey = names.trackKey(before.tracks[1])
	taxonomy:setTag(pathKey, tag.id, true)
	taxonomy:setRating(pathKey, 4)
	taxonomy:recordListen(before.tracks[1], before, nil, 100)

	local after = solo("/music", "/music/a.flac", "00aa11bb22cc33dd")
	test.truthy(taxonomy:adopt(after), "something moved, so the caller saves")
	local key = names.trackKey(after.tracks[1])
	test.truthy(taxonomy:isTagged(key, tag.id))
	test.equal(taxonomy:rating(key), 4)
	test.equal(assert(taxonomy:trackMetric(after.tracks[1])).count, 1)
	test.falsy(taxonomy:isTagged(pathKey, tag.id), "nothing is left under the path")
	test.equal(taxonomy:rating(pathKey), 0)
	test.falsy(taxonomy:adopt(after), "and a second pass finds nothing to move")
end)
