local test = require("lde-test")
local fs = require("fs")
local artworkCache = require("beat.music.artwork_cache")

test.it("names one source, modified time and size the same way every time", function()
	local first = artworkCache.file("/music", "/music/a/cover.jpg", 12, 512)
	local again = artworkCache.file("/music", "/music/a/cover.jpg", 12, 512)
	local changed = artworkCache.file("/music", "/music/a/cover.jpg", 13, 512)

	test.equal(first, again)
	test.truthy(first ~= changed, "a modified picture is a different cache entry")
end)

test.it("prunes covers the completed scan did not use", function()
	local root = os.tmpname() .. "-beat-covers"
	local usedFile = artworkCache.file(root, "/music/a.jpg", 1, 512)
	local unusedFile = artworkCache.file(root, "/music/b.jpg", 1, 512)
	local dir = artworkCache.directory(root)
	fs.mkdirAll(dir)

	test.truthy(fs.write(usedFile, "used"))
	test.truthy(fs.write(unusedFile, "unused"))

	local removed = artworkCache.prune(root, { [usedFile] = true})
	test.equal(removed, 1)
	test.truthy(fs.isfile(usedFile))
	test.falsy(fs.isfile(unusedFile))

	fs.delete(usedFile)
	fs.rmdir(dir)
end)
