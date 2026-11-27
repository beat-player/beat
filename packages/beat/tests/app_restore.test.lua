-- The page a launch opens again: the app writes the page it is on to the settings file, and a
-- launch reads it once the library cache it names is there. A test runs a launch twice by calling
-- `App:init` twice against one config directory, which is how the real thing starts.
local test = require("lde-test")
local fs = require("fs")
local json = require("json")
local threading = require("threading")
local paths = require("beat.paths")
local Library = require("beat.music.library")
local Queue = require("beat.app.services.playback.queue")
local App = require("beat.app")

local configDirectory = os.tmpname() .. "-beat-restore"
os.remove(configDirectory)
fs.mkdirAll(configDirectory)

local realDirectory = paths.directory
paths.directory = function() return configDirectory end

test.afterAll(function()
	paths.directory = realDirectory
	fs.rmdir(configDirectory)
end)

--- A fresh config directory, so a case never starts from what the one before it wrote.
local function freshConfig()
	fs.rmdir(configDirectory)
	fs.mkdirAll(configDirectory)
end

--- Two albums by two artists, in the order the scan found them. A library cache replays this
--- order, so `order` reverses it the way a rescan in another order would.
---@param root string
---@param order number[]?
---@return beat.Library
local function fixture(root, order)
	local library = Library.new(root)
	for _, albumAt in ipairs(order or { 1, 2 }) do
		local artist = "Artist " .. albumAt
		local dir = root .. "/" .. artist .. "/Album " .. albumAt
		for trackAt = 1, 2 do
			library:add(
				{
					format = "WAV",
					sampleRate = 44100,
					channels = 2,
					duration = 180,
					hasPicture = false,
					tags = {
						title = "Album " .. albumAt .. " Track " .. trackAt,
						artist = artist,
						album = "Album " .. albumAt,
						albumArtist = artist,
						track = trackAt
					}
				},
				{ path = dir .. "/" .. trackAt .. ".wav", dir = dir, name = trackAt .. ".wav", ext = "wav" },
				nil
			)
		end
	end
	library:finish()
	return library
end

--- A launch that has already read its library: `scan = false` keeps `init` from looking for a
--- cache, and the test hands it the one the next launch will read.
---@param library beat.Library
local function useLibrary(library)
	App.services.settings.values.root = library.root
	App.services.settings:save()
	App.services.library.current = library
	App.services.library:save()
end

test.it("opens the album the last launch was on, even after a rescan reorders it", function()
	freshConfig()
	App:init({ scan = false })
	local library = fixture("/restore-fixtures")
	useLibrary(library)
	local wanted = library.albums[2]

	App:go({ kind = "album", id = wanted.id })
	test.equal(App.page.kind, "album")
	test.equal(App.page.id, wanted.id)

	-- The next launch scans the same folders in the other order: the same album is a different id.
	local rescanned = fixture("/restore-fixtures", { 2, 1 })
	App.services.library.current = rescanned
	App.services.library:save()
	App:init()
	App.services.library:load()

	local restored = App.services.library.current
	test.truthy(restored ~= nil, "the library cache is read")
	test.equal(App.page.kind, "album", "the launch opens the album page once the library is in")
	local album = restored:album(App.page.id)
	test.truthy(album ~= nil, "the page names an album the new library has")
	test.equal(album.key, wanted.key, "the saved key found the album, not the id from the old scan")
	test.equal(album.title, wanted.title)

	test.equal(#App.history, 1, "home sits under the restored page")
	test.equal(App.history[1].kind, "home")
	App:back()
	test.equal(App.page.kind, "home", "back leaves the restored page for home")
	App.services.playback.player:close()
end)

test.it("falls back to home when the saved album is gone", function()
	freshConfig()
	App:init({ scan = false })
	local library = fixture("/gone-fixtures")
	useLibrary(library)

	App:go({ kind = "album", id = library.albums[2].id })
	App.services.library.current = fixture("/gone-fixtures", { 1 })
	App.services.library:save()
	App:init()
	App.services.library:load()

	local restored = App.services.library.current
	test.truthy(restored ~= nil)
	test.equal(App.page.kind, "home", "a page for an album the scan dropped is not opened")
	test.equal(#App.history, 0, "home is the first page, so there is nothing under it")
	App.services.playback.player:close()
end)

test.it("draws before the cached library is read, then restores the page and the queue", function()
	freshConfig()
	App:init({ scan = false })
	local library = fixture("/deferred-fixtures")
	useLibrary(library)
	local wanted = library.albums[1]
	App:go({ kind = "album", id = wanted.id })

	local queue = Queue.new(library.tracks, 2, { source = "album" })
	local bytes = json.encode({ version = 1, queue = queue:pack(), seconds = 12 })
	test.truthy(fs.write(paths.file("session.json"), bytes), "the old session file is written")

	App:init()
	local service = App.services.library
	test.equal(service:isLoading(), true, "the cache is not parsed in App:init")
	test.equal(App.page.kind, "home", "the shell shows home until the saved album can be resolved")
	test.equal(App.services.scan.job, nil, "no scan runs while the cache is being read")
	test.equal(App.services.playback.player.queue, nil, "the session waits for the library")

	local home = require("beat.app.pages.home")
	test.truthy(home.view(App, App.page, { width = 1200, height = 800 }) ~= nil, "home draws its empty state")

	-- The first ticks read the cache on a worker, a batch of records at a time.
	local ticks = 0
	while service:isLoading() and ticks < 1000 do
		local _, busy = service:step(0)
		if busy then threading.sleep(1) end
		ticks += 1
	end
	test.equal(service:isLoading(), false, "the cache is in after a few ticks")
	test.truthy(service.current ~= nil, "the launch has its library")
	test.equal(App.page.kind, "album", "the saved page is opened once the library is in")
	test.equal(App.page.id, wanted.id)
	test.equal(App.services.scan.job, nil, "the loaded cache is not scanned again")

	local restored = assert(App.services.playback.player.queue)
	test.equal(#restored.tracks, #library.tracks, "the session is restored after the library")
	test.equal(assert(restored:current()).path, library.tracks[2].path)
	test.equal(App.services.playback.player:position(), 12, "it starts where the old session stopped")
	App.services.playback.player:close()
end)

test.it("keeps the library, its tags and its queue when the app is built again", function()
	freshConfig()
	App:init({ scan = false })
	local library = fixture("/restart-fixtures")
	useLibrary(library)
	local taxonomy = App.services.collections.taxonomy
	local queue = Queue.new(library.tracks, 1, { source = "album" })
	App.services.playback.player.queue = queue
	App.services.playback.player.startAt = 42

	App:restart()

	test.equal(App.services.library.current, library, "the rebuilt app keeps the library it had")
	test.equal(App.services.collections.taxonomy, taxonomy, "its tags are not read back from disk")
	test.equal(App.services.playback.player.queue, queue, "and the queue it was playing from")
	test.equal(App.services.playback.player:position(), 42, "where it was in that queue")
	App.services.playback.player:close()
end)

test.it("loads the queue from an old session that has no page in it", function()
	freshConfig()
	App:init({ scan = false })
	local library = fixture("/session-fixtures")
	useLibrary(library)

	local queue = Queue.new(library.tracks, 2, { source = "album" })
	local bytes = json.encode({ version = 1, queue = queue:pack(), seconds = 37 })
	test.truthy(fs.write(paths.file("session.json"), bytes), "the old session file is written")

	App:init()
	App.services.library:load()
	local restored = App.services.playback.player.queue
	test.truthy(restored ~= nil, "the launch restores the session")
	test.equal(#restored.tracks, #library.tracks)
	test.equal(assert(restored:current()).path, library.tracks[2].path)
	test.equal(App.services.playback.player:position(), 37, "it starts where the old session stopped")
	App.services.playback.player:close()
end)
