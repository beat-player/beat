local test = require("lde-test")
local ffi = require("ffi")
local fs = require("fs")
local path = require("path")
local image = require("image")
local Library = require("beat.music.library")
local artwork = require("beat.music.artwork")

local function solid(width, height, r, g, b)
	local picture = image.new(width, height, 4)
	picture:fill(r, g, b, 255)
	return picture
end

test.it("fits a cover to a square by cropping its long side", function()
	local source = solid(200, 100, 255, 0, 0)
	local fitted = artwork.fit(source, 64)

	test.equal(fitted.width, 64)
	test.equal(fitted.height, 64)

	local r, g, b = artwork.dominant(fitted)
	test.truthy(r > 0.95, "the redness survives the downscale")
	test.truthy(g < 0.05)
	test.truthy(b < 0.05)

	fitted:close()
	source:close()
end)

test.it("copies a cropped square one row at a time", function()
	local source = image.new(4, 2, 4)
	local pixels = ffi.cast("uint8_t*", source.pixels)
	for y = 0, 1 do
		for x = 0, 3 do
			local at = (y * 4 + x) * 4
			pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3] = x + 1, y + 1, 0, 255
		end
	end

	local fitted = artwork.fit(source, 2)
	local out = ffi.cast("uint8_t*", fitted.pixels)

	-- The crop starts at x=1, so the second output row starts at the source's x=1 again. A
	-- contiguous copy would have carried on from the previous row and put x=0 there.
	test.equal(out[8], 2)
	test.equal(out[12], 3)

	fitted:close()
	source:close()
end)

test.it("never upscales a small cover", function()
	local source = solid(32, 48, 0, 200, 0)
	local fitted = artwork.fit(source, 512)

	test.equal(fitted.width, 32, "the short side is the square")
	test.equal(fitted.height, 32)

	fitted:close()
	source:close()
end)

test.it("returns a dominant colour from the pixels, not the average of black borders", function()
	local source = solid(80, 80, 20, 40, 200)
	local r, g, b = artwork.dominant(source)

	test.truthy(r < 0.15)
	test.truthy(g > 0.1 and g < 0.25)
	test.truthy(b > 0.7)

	source:close()
end)

test.it("uses the picture inside a track for its album cover", function()
	local audio = require("treble.audio")
	local path = require("path")
	local here = (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".")
	local file = path.join(here, "..", "fixtures", "tagged.flac")
	local info = assert(audio.inspect(file))
	test.truthy(info.hasPicture)

	local library = Library.new("/tmp")
	library:add(info, { path = file, dir = here, name = "tagged.flac", ext = "flac" })
	library:finish()
	local album = library.albums[1]
	local coverTrack = assert(album.coverTrack)
	test.equal(coverTrack.path, file)

	local cache = assert(artwork.cacheCover({ path = file, hasPicture = true, modified = 1 }, 128, "/beat-art-test"))
	album.coverCache = cache

	local fitted, colour = artwork.forAlbum(album, 128)
	test.truthy(fitted ~= nil)
	test.truthy(colour ~= nil)
	if fitted ~= nil then
		test.truthy(fitted.width > 0)
		test.equal(fitted.width, fitted.height)
		fitted:close()
	end
end)

test.it("makes a cached cover again when its file was deleted", function()
	local dir = os.tmpname() .. "-beat-art-rewrite"
	fs.mkdirAll(dir)
	local cover = path.join(dir, "cover.png")
	local picture = solid(80, 40, 10, 120, 200)
	test.truthy(fs.write(cover, assert(picture:encode("png"))))
	picture:close()

	local file = path.join(dir, "cache", "cover.jpg")
	local album = {
		id = 1,
		key = "Album\0Artist",
		title = "Album",
		artist = "Artist",
		tracks = { { path = path.join(dir, "1.flac"), modified = 7 } },
		coverPath = cover,
		coverCache = file,
		modified = 7
	}

	local gone, _, err = artwork.forAlbum(album, 32)
	test.equal(gone, nil, "a cleaned cache has nothing to load: " .. tostring(err))

	local source = assert(artwork.source(album))
	local remade, writeErr = artwork.rewriteCache(source, file, artwork.CACHE_SIZE)
	test.equal(remade, file)
	test.truthy(fs.isfile(file), "the cover is written where the album names it: " .. tostring(writeErr))

	local fitted = artwork.forAlbum(album, 32)
	test.truthy(fitted ~= nil, "the remade cache loads again")
	if fitted ~= nil then
		test.equal(fitted.width, fitted.height)
		fitted:close()
	end

	fs.rmdir(dir)
end)

test.it("names the track with the picture, or the picture beside the tracks, as an album's source", function()
	local track = { path = "/music/a.flac", hasPicture = true, modified = 5 }
	local embedded = artwork.source({ coverTrack = track, coverPath = nil, tracks = { track } })
	test.truthy(embedded ~= nil)
	test.equal(embedded.path, "/music/a.flac")
	test.equal(embedded.hasPicture, true)

	local folder = artwork.source({
		coverPath = "/music/cover.jpg",
		modified = 9,
		tracks = { { path = "/music/b.flac", modified = 9 } }
	})
	test.truthy(folder ~= nil)
	test.equal(folder.coverPath, "/music/cover.jpg")
	test.equal(folder.hasPicture, false)
	test.equal(folder.path, "/music/b.flac")

	test.equal(artwork.source({ tracks = {} }), nil, "an album with no picture has no source")
end)

test.it("does not read the music folder when an album has no cached cover", function()
	local album = { id = 1, key = "Album\0Artist", title = "Album", artist = "Artist", artistId = 1, tracks = {}, duration = 0, trackCount = 0, coverPath = "/definitely/not/a/real/cover.png", coverCache = nil, modified = 0, hash = "hash" }

	local fitted, colour, err = artwork.forAlbum(album, 128)
	test.equal(fitted, nil)
	test.equal(colour, nil)
	test.equal(err, "cover has not been cached yet")
end)

test.it("reports when an album gains its first cached cover", function()
	local library = Library.new("/tmp/cache-test")
	local info = { format = "WAV", sampleRate = 44100, channels = 2, duration = 10, hasPicture = false, tags = { title = "One", artist = "Artist", album = "Album", albumArtist = "Artist" } }

	local first, gained = library:add(info, { path = "/tmp/cache-test/1.wav", dir = "/tmp/cache-test", name = "1.wav", ext = "wav" })
	test.falsy(gained)
	test.equal(first.albumId, 1)

	local second, gainedAgain = library:add(info, { path = "/tmp/cache-test/2.wav", dir = "/tmp/cache-test", name = "2.wav", ext = "wav" }, nil, "/tmp/cover.jpg")
	test.truthy(gainedAgain)
	test.equal(second.albumId, first.albumId)
	test.equal(library.albums[1].coverCache, "/tmp/cover.jpg")
end)
