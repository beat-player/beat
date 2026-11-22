-- The built-in lists: what they are called, how their ids resolve, and the order each one puts a
-- library in. They are worked out from plays and the library's own order rather than saved, so
-- the tests drive `recordListen` and read the result back through the taxonomy the app uses.
local test = require("lde-test")
local Library = require("beat.music.library")
local Taxonomy = require("beat.app.services.collections.taxonomy")
local Smart = require("beat.app.services.collections.smart")

--- Four tracks in one album, in the order a scan found them.
---@return beat.Library
local function library()
	local lib = Library.new("/music")
	for at, title in ipairs({ "A", "B", "C", "D" }) do
		lib:add(
			{
				format = "FLAC",
				sampleRate = 44100,
				channels = 2,
				duration = 180,
				hasPicture = false,
				tags = { title = title, artist = "artist", album = "album", albumArtist = "artist", track = at }
			},
			{ path = "/music/" .. title .. ".flac", dir = "/music", name = title .. ".flac", ext = "flac" },
			nil
		)
	end
	lib:finish()
	return lib
end

---@param id number
---@param taxonomy beat.Taxonomy
---@param lib beat.Library
---@return string
local function titles(id, taxonomy, lib)
	local list = {}
	for at, track in ipairs(Smart.tracks(id, taxonomy, lib)) do list[at] = track.title end
	return table.concat(list, ",")
end

test.it("orders every built-in list from what has been played", function()
	local lib = library()
	local taxonomy = Taxonomy.new()
	taxonomy:recordListen(lib.tracks[2], lib, nil, 100)
	taxonomy:recordListen(lib.tracks[2], lib, nil, 200)
	taxonomy:recordListen(lib.tracks[4], lib, nil, 150)

	test.equal(titles(-1, taxonomy, lib), "B,D", "most played keeps only songs that have been heard")
	test.equal(titles(-2, taxonomy, lib), "A,C,D,B", "least played includes songs with no plays")
	test.equal(titles(-3, taxonomy, lib), "B,D", "recently played follows the last play")
	test.equal(titles(-4, taxonomy, lib), "D,C,B,A", "recently added is the scan's order reversed")
	test.equal(titles(-5, taxonomy, lib), "A,C", "never played is what has no play at all")
end)

test.it("resolves the built-in ids through the taxonomy and names them like a playlist", function()
	local lib = library()
	local taxonomy = Taxonomy.new()
	local mostPlayed = assert(taxonomy:playlist(-1))
	test.equal(mostPlayed.name, "Most played")
	test.truthy(mostPlayed.builtin, "the page can tell a built-in list from one that was saved")
	test.equal(Smart.subtitle(mostPlayed), "What you have heard most")
	test.equal(#taxonomy:playlistTracks(mostPlayed, lib), 0, "nothing has been heard yet")

	taxonomy:recordListen(lib.tracks[1], lib)
	test.equal(#taxonomy:playlistTracks(mostPlayed, lib), 1, "the list follows the library and its plays")
	test.equal(taxonomy:playlist(-99), nil, "an id outside the built-ins is still not a playlist")
	test.equal(#Smart.all(), 5, "every built-in list is always there")
end)
