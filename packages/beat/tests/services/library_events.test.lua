-- A library replacement is a message because what a scan starts from is not only the library
-- service's business: the queue it invalidated and whatever a plugin keeps by track identity have
-- to hear that every id from the old library is gone.
local test = require("lde-test")
local LibraryService = require("beat.app.services.library")

test.it("announces the library a scan starts from", function()
	local emitted = {}
	local service = LibraryService.new({
		settings = { values = {}},
		options = { scan = false},
		emit = function(message) emitted[#emitted + 1] = message end,
	})

	service:replace("/roots/one")

	test.equal(#emitted, 1)
	test.equal(emitted[1].type, "libraryReplaced")
	test.equal(service.current.root, "/roots/one")
end)

test.it("announces every replacement, not only the first", function()
	local emitted = {}
	local service = LibraryService.new({
		settings = { values = {}},
		options = { scan = false},
		emit = function(message) emitted[#emitted + 1] = message end,
	})

	service:replace("/roots/one")
	service:replace("/roots/two")

	test.equal(#emitted, 2)
	test.equal(emitted[2].type, "libraryReplaced")
	test.equal(service.current.root, "/roots/two")
end)
