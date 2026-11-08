-- Adding one folder to a library that already exists: the folder replaces what was there under
-- it, the rest of the library and the queue stay put, and the cache is written. The scan worker
-- is a stand-in, so no process is started and no music folder is read.
local test = require("lde-test")
local fs = require("fs")
local paths = require("beat.paths")
local Library = require("beat.music.library")
local LibraryCache = require("beat.app.services.library.cache")
local Queue = require("beat.app.services.playback.queue")
local ScanJob = require("beat.app.services.scan.job")
local App = require("beat.app")

local configDirectory = os.tmpname() .. "-beat-folder-add"
os.remove(configDirectory)
fs.mkdirAll(configDirectory)

local realDirectory = paths.directory
paths.directory = function() return configDirectory end
local realScanJobStart = ScanJob.start

test.afterAll(function()
	paths.directory = realDirectory
	fs.rmdir(configDirectory)
end)

test.afterEach(function()
	ScanJob.start = realScanJobStart
	if App.services ~= nil and App.services.playback ~= nil then App.services.playback.player:close() end
end)

---@param root string
---@param dir string
---@param name string
---@param title string
local function trackEvent(root, dir, name, title)
	return {
		type = "track",
		info = {
			format = "MP3",
			sampleRate = 44100,
			channels = 2,
			duration = 120,
			hasPicture = false,
			tags = {
				title = title,
				artist = "Artist",
				album = "Album",
				albumArtist = "Artist",
				track = tonumber(name:match("^(%d+)")) or 1
			}
		},
		entry = { path = dir .. "/" .. name, dir = dir, name = name, ext = "mp3", key = root }
	}
end

---@param events table[]
---@param phase string
local function fakeJob(events, phase)
	local job = {
		events = events,
		done = true,
		latest = { phase = phase or "done", files = #events, inspected = #events, tracks = #events, skipped = 0, errors = {} },
		closed = false
	}
	function job:poll()
		local queued = self.events
		self.events = {}
		return queued, #queued > 0
	end
	function job:isDone() return self.done end
	function job:hasPending() return #self.events > 0 end
	function job:progress() return self.latest end
	function job:close() self.closed = true end
	function job:cancel() end
	return job
end

test.it("adds a folder without duplicating it and leaves the queue alone", function()
	App:init({ scan = false })
	local library = Library.new("/library")
	library:add({ format = "MP3", sampleRate = 44100, channels = 2, duration = 100, hasPicture = false, tags = { title = "Old One", artist = "Artist", album = "Album", albumArtist = "Artist", track = 1 } }, { path = "/downloads/Album/01.mp3", dir = "/downloads/Album", name = "01.mp3", ext = "mp3" }, nil)
	library:add({ format = "MP3", sampleRate = 44100, channels = 2, duration = 100, hasPicture = false, tags = { title = "Elsewhere", artist = "Artist", album = "Other", albumArtist = "Artist", track = 1 } }, { path = "/library/Other/01.mp3", dir = "/library/Other", name = "01.mp3", ext = "mp3" }, nil)
	library:finish()
	App.services.library.current = library

	local queue = Queue.new({ library.tracks[1] }, 1)
	App.services.playback.player.queue = queue

	local job = fakeJob({ trackEvent("/downloads/Album", "/downloads/Album", "01.mp3", "New One"), trackEvent("/downloads/Album", "/downloads/Album", "02.mp3", "New Two") })
	local realStart = ScanJob.start
	ScanJob.start = function(folder)
		test.equal(folder, "/downloads/Album")
		return job
	end

	local window = { width = 1200, height = 720, shouldRedraw = false }
	local ok, err = pcall(function()
		App:act({ type = "libraryAddFolder", path = "/downloads/Album" })
		test.equal(#library.tracks, 1, "the old track under the folder is dropped before the scan")
		App:tick(10, window)
	end)
	ScanJob.start = realStart
	if not ok then error(err, 0) end

	test.equal(job.closed, true)
	test.equal(#library.tracks, 3, "the two new tracks joined the one outside the folder")
	local titles = {}
	for _, track in ipairs(library.tracks) do titles[#titles + 1] = track.title end
	table.sort(titles)
	test.equal(table.concat(titles, ","), "Elsewhere,New One,New Two", "the folder was replaced, not duplicated")

	test.equal(App.services.playback.player.queue, queue, "the queue was not rebuilt")
	test.equal(#queue.tracks, 1, "the queue was not reset")

	local cached = LibraryCache.load("/library")
	test.truthy(cached ~= nil, "the library cache was written")
	if cached ~= nil then
		test.equal(#cached.tracks, 3, "the cache has the replaced folder")
	end
end)

test.it("keeps the library when the folder scan fails", function()
	App:init({ scan = false })
	local library = Library.new("/library")
	library:add({ format = "MP3", sampleRate = 44100, channels = 2, duration = 100, hasPicture = false, tags = { title = "Kept", artist = "Artist", album = "Album", albumArtist = "Artist", track = 1 } }, { path = "/library/Kept/01.mp3", dir = "/library/Kept", name = "01.mp3", ext = "mp3" }, nil)
	library:finish()
	App.services.library.current = library

	local job = fakeJob({}, "error")
	job.error = "the worker could not start"
	local realStart = ScanJob.start
	ScanJob.start = function() return job end

	local window = { width = 1200, height = 720, shouldRedraw = false }
	local ok, err = pcall(function() App:act({ type = "libraryAddFolder", path = "/elsewhere" }) end)
	if ok then ok, err = pcall(function() App:tick(10, window) end) end
	ScanJob.start = realStart
	if not ok then error(err, 0) end

	test.equal(#library.tracks, 1, "a failed folder add leaves the library it found")
	test.equal(job.closed, true)
end)
