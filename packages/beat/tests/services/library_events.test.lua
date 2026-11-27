-- A library replacement is a message because what a scan starts from is not only the library
-- service's business: the queue it invalidated and whatever a plugin keeps by track identity have
-- to hear that every id from the old library is gone.
local test = require("lde-test")
local LibraryService = require("beat.app.services.library")
local Library = require("beat.music.library")

test.it("announces the library a scan starts from", function()
	---@type beat.Message[]
	local emitted = {}
	local service = LibraryService.new({ settings = { values = {} }, options = { scan = false }, emit = function(message) emitted[#emitted + 1] = message end })

	service:replace("/roots/one")

	test.equal(#emitted, 1)
	test.equal(emitted[1].type, "libraryReplaced")
	local current = assert(service.current)
	test.equal(current.root, "/roots/one")
end)

test.it("announces every replacement, not only the first", function()
	---@type beat.Message[]
	local emitted = {}
	local service = LibraryService.new({ settings = { values = {} }, options = { scan = false }, emit = function(message) emitted[#emitted + 1] = message end })

	service:replace("/roots/one")
	service:replace("/roots/two")

	test.equal(#emitted, 2)
	test.equal(emitted[2].type, "libraryReplaced")
	local current = assert(service.current)
	test.equal(current.root, "/roots/two")
end)

---@param root string
---@return beat.LibraryService
local function service(root)
	return LibraryService.new({ settings = { values = { root = root } }, options = {}, emit = function() end })
end

--- Adds a track under an album of its own so a sort has something to order.
---@param library beat.Library
---@param title string
local function addTrack(library, title)
	local path = "/roots/one/" .. title .. ".flac"
	library:add({
		format = "FLAC",
		duration = 100,
		tags = { title = title, artist = "Artist", album = title .. " Album" }
	}, { path = path, dir = "/roots/one", name = title .. ".flac", ext = "flac" })
end

test.it("holds a rebuild to eight a second while the cache comes in", function()
	local library = service("/roots/one")
	test.equal(library:paceChange(0), true, "the first change is drawn at once")
	test.equal(library:paceChange(0.05), false, "another in the same frame is not")
	test.equal(library:paceChange(0.2), true, "the next eighth of a second draws one")
end)

test.it("keeps the album order a loading page already has, then sorts the closed library", function()
	local library = service("/roots/one")
	local current = Library.new("/roots/one")
	library.current = current
	library.loading = true
	addTrack(current, "One")
	addTrack(current, "Two")

	local first = library:sorted("artist")
	test.equal(#first, 2)

	addTrack(current, "Three")
	test.equal(library:sorted("artist"), first, "a batch arriving does not sort again within the second")

	library.sortedAt = 0
	local refreshed = library:sorted("artist")
	test.truthy(refreshed ~= first, "after the second the order is computed again")
	test.equal(#refreshed, 3)

	library.loading = false
	addTrack(current, "Four")
	local latest = library:sorted("artist")
	test.equal(#latest, 4, "a closed library sorts on every change again")
end)

test.it("closes a scan's sort a slice a tick and announces it once", function()
	local library = service("/roots/one")
	local current = Library.new("/roots/one")
	library.current = current
	for at = 1, 4 do addTrack(current, "Song " .. at) end

	local changed, finished = 0, 0
	library.changed:connect(function() changed += 1 end)
	library.finished:connect(function(lib)
		finished += 1
		test.equal(lib, current)
	end)

	library:finish()
	test.equal(changed, 0, "the sort is not run where it was asked for")
	test.equal(finished, 0)
	test.equal(library.finishing, true)

	local slices = 0
	while library.finishing do
		library:finishStep(0)
		slices += 1
		assert(slices < 1000)
	end
	test.truthy(slices > 1, "the sort took more than one slice")
	test.equal(changed, 1, "the closed library is announced once")
	test.equal(finished, 1)
	test.equal(current.ready, true)
end)

test.it("finishes a sort the app was closing in the middle of", function()
	local library = service("/roots/one")
	local current = Library.new("/roots/one")
	library.current = current
	for at = 1, 4 do addTrack(current, "Song " .. at) end
	library:finish()
	library:finishStep(0)
	test.equal(library.finishing, true, "the sort is still running")

	library:close()
	test.equal(current.ready, true, "the library handed on is closed")
	test.equal(current.finishing, nil)
end)
