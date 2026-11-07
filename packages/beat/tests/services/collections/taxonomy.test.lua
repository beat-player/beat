local test = require("lde-test")
local Taxonomy = require("beat.app.services.collections.taxonomy")

local function library()
	return {
	tracks = {
	{ path = "/music/a.flac", title = "A"},
	{ path = "/music/b.flac", title = "B"},
	{ path = "/music/c.flac", title = "C"},
	},
	}
end

test.it("names tags case-insensitively and toggles them on a track", function()
	local taxonomy = Taxonomy.new()
	local high = taxonomy:addTag("  High Energy ")
	local late = taxonomy:addTag("Late Night")

	test.truthy(high and late)
	test.equal(high.name, "High Energy")
	test.falsy(taxonomy:addTag("high energy"), "a tag name is one name regardless of case")
	test.equal(#taxonomy:visibleTags(), 2)

	test.truthy(taxonomy:toggleTag("/music/a.flac", high.id))
	test.truthy(taxonomy:isTagged("/music/a.flac", high.id))
	test.falsy(taxonomy:isTagged("/music/a.flac", late.id))
	test.equal(high.count, 1)
	test.falsy(taxonomy:toggleTag("/music/a.flac", high.id))
	test.equal(high.count, 0)
end)

test.it("filters a smart playlist by all or any of its tags", function()
	local taxonomy = Taxonomy.new()
	local high = assert(taxonomy:addTag("High Energy"))
	local late = assert(taxonomy:addTag("Late Night"))
	local lib = library()

	taxonomy:setTag("/music/a.flac", high.id, true)
	taxonomy:setTag("/music/a.flac", late.id, true)
	taxonomy:setTag("/music/b.flac", high.id, true)

	local all = assert(taxonomy:addPlaylist("Both", true, { high.id, late.id}, "all"))
	local any = assert(taxonomy:addPlaylist("Either", true, { high.id, late.id}, "any"))
	local allTracks = taxonomy:playlistTracks(all, lib)
	local anyTracks = taxonomy:playlistTracks(any, lib)

	test.equal(#allTracks, 1)
	test.equal(allTracks[1].path, "/music/a.flac")
	test.equal(#anyTracks, 2)
end)

test.it("keeps manual playlist membership in a hidden tag", function()
	local taxonomy = Taxonomy.new()
	local lib = library()
	local playlist = assert(taxonomy:addPlaylist("Favourites", false))
	---@cast playlist beat.Playlist

	taxonomy:setPlaylistTrack(playlist, "/music/c.flac", true)
	local manualTracks = taxonomy:playlistTracks(playlist, lib)
	test.equal(#manualTracks, 1)
	test.equal(manualTracks[1].path, "/music/c.flac")
	test.equal(#taxonomy:visibleTags(), 0, "the manual membership tag stays out of the visible list")
	test.truthy(playlist.hiddenTagId ~= nil)

	taxonomy:setPlaylistTrack(playlist, "/music/c.flac", false)
	test.equal(#taxonomy:playlistTracks(playlist, lib), 0)
end)

test.it("round-trips tags and playlists through its packed form", function()
	local taxonomy = Taxonomy.new()
	local high = assert(taxonomy:addTag("High Energy"))
	local smart = assert(taxonomy:addPlaylist("High", true, { high.id}, "all"))
	local manual = assert(taxonomy:addPlaylist("Manual", false))
	taxonomy:setTag("/music/a.flac", high.id, true)
	taxonomy:setPlaylistTrack(manual, "/music/b.flac", true)

	local loaded = Taxonomy.unpack(taxonomy:pack())
	local lib = library()
	test.equal(#loaded:visibleTags(), 1)
	test.equal(loaded:visibleTags()[1].name, "High Energy")
	test.equal(#loaded:playlistTracks(loaded:playlist(smart.id), lib), 1)
	test.equal(#loaded:playlistTracks(loaded:playlist(manual.id), lib), 1)
	test.truthy(loaded.tagById[assert(loaded:playlist(manual.id).hiddenTagId)].hidden)
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
	taxonomy:setTag("/music/a.flac", tag.id, true)
	taxonomy:setPlaylistTrack(playlist, "/music/b.flac", true)

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
	lib.albums = {{ id = 1, key = "artist\0album", title = "Album", artist = "Artist"}}
	lib.albumById = { [1] = lib.albums[1]}
	function lib:album(id) return self.albumById[id] end
	lib.tracks[1].albumId = 1
	taxonomy:setTag("/music/a.flac", tag.id, true)

	taxonomy:recordListen(lib.tracks[1], lib, auto.id, 1234)
	test.equal(taxonomy.metrics.tracks["/music/a.flac"].count, 1)
	test.equal(taxonomy.metrics.albums["artist\0album"].count, 1)
	test.equal(taxonomy.metrics.tags[tag.id].count, 1)
	test.equal(taxonomy.metrics.playlists[auto.id].count, 1)
	local recent = taxonomy:recentAlbums(lib, 5)
	test.equal(#recent, 1)
	test.equal(recent[1].key, "artist\0album")

	local loaded = Taxonomy.unpack(taxonomy:pack())
	test.equal(loaded.metrics.tracks["/music/a.flac"].count, 1)
	test.equal(loaded.metrics.albums["artist\0album"].last, 1234)
end)
