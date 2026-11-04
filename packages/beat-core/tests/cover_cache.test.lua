local test = require("lde-test")
local fs = require("fs")
local core = require("beat-core")

test.it("names one source, modified time and size the same way every time", function()
	local first = core.cover_cache.file("/music", "/music/a/cover.jpg", 12, 512)
	local again = core.cover_cache.file("/music", "/music/a/cover.jpg", 12, 512)
	local changed = core.cover_cache.file("/music", "/music/a/cover.jpg", 13, 512)

	test.equal(first, again)
	test.truthy(first ~= changed, "a modified picture is a different cache entry")
end)

test.it("prunes covers the completed scan did not use", function()
	local root = os.tmpname() .. "-beat-covers"
	local usedFile = core.cover_cache.file(root, "/music/a.jpg", 1, 512)
	local unusedFile = core.cover_cache.file(root, "/music/b.jpg", 1, 512)
	local dir = core.cover_cache.directory(root)
	fs.mkdirAll(dir)

	test.truthy(fs.write(usedFile, "used"))
	test.truthy(fs.write(unusedFile, "unused"))

	local removed = core.cover_cache.prune(root, { [usedFile] = true})
	test.equal(removed, 1)
	test.truthy(fs.isfile(usedFile))
	test.falsy(fs.isfile(unusedFile))

	fs.delete(usedFile)
	fs.rmdir(dir)
end)
