-- Editing tags from the dialog: only the fields changed are written, the file gets them, and the
-- track takes its new place in the library and in the queue without a rescan.
local test = require("lde-test")
local fs = require("fs")
local audio = require("treble.audio")
local paths = require("beat.paths")
local Library = require("beat.music.library")
local Queue = require("beat.app.services.playback.queue")
local App = require("beat.app")

local here = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])")
local configDirectory = os.tmpname() .. "-beat-metadata"
os.remove(configDirectory)
fs.mkdirAll(configDirectory)
local realDirectory = paths.directory
paths.directory = function() return configDirectory end

test.afterAll(function()
	paths.directory = realDirectory
	fs.rmdir(configDirectory)
end)

test.afterEach(function()
	if App.services ~= nil and App.services.playback ~= nil then App.services.playback.player:close() end
end)

---@return string folder, string file
local function copyFixture()
	local folder = os.tmpname() .. "-beat-metadata-music"
	os.remove(folder)
	fs.mkdirAll(folder)
	local source = assert(io.open(here .. "fixtures/tagged.opus", "rb"))
	local data = source:read("*a")
	source:close()
	local file = folder .. "/song.opus"
	local out = assert(io.open(file, "wb"))
	out:write(data)
	out:close()
	return folder, file
end

test.it("writes the changed fields and updates the library and the queue", function()
	App:init({ scan = false })
	local folder, file = copyFixture()
	local before = assert(audio.tags(file))

	local library = Library.new(folder)
	library:add(assert(audio.inspect(file)), { path = file, dir = folder, name = "song.opus", ext = "opus" }, nil)
	library:finish()
	App.services.library.current = library
	local old = library.tracks[1]
	-- A removed track's column values go with it, so the fingerprint is read now.
	local fingerprint = old.fingerprint
	local queue = Queue.new({ old }, 1)
	App.services.playback.player.queue = queue

	App:act({ type = "open", overlay = "metadata_editor", kind = "track", id = old.id })
	App:act({ type = "metadataDraft", field = "title", value = "Edited Title" })
	App:act({ type = "metadataDraft", field = "genre", value = "" })
	App:act({ type = "metadataSave" })

	local window = { width = 1200, height = 720, shouldRedraw = false }
	local deadline = os.clock() + 10
	while App.services.metadata.task ~= nil and os.clock() < deadline do App:tick(10, window) end
	test.equal(App.services.metadata.task, nil, "the write finished")

	local tags = assert(audio.tags(file))
	test.equal(tags.title, "Edited Title")
	test.equal(tags.genre, nil, "an emptied field is removed")
	test.equal(tags.artist, before.artist, "a field left alone is kept")
	test.equal(tags.album, before.album)

	test.equal(#library.tracks, 1, "the track was replaced, not added again")
	local track = library.tracks[1]
	test.equal(track.title, "Edited Title")
	test.equal(track.fingerprint, fingerprint, "the audio is untouched")
	test.equal(queue.tracks[1], track, "the queue holds the new track")

	fs.rmdir(folder)
end)

test.it("refuses a track number that is not a number", function()
	App:init({ scan = false })
	local folder, file = copyFixture()
	local library = Library.new(folder)
	library:add(assert(audio.inspect(file)), { path = file, dir = folder, name = "song.opus", ext = "opus" }, nil)
	library:finish()
	App.services.library.current = library

	App:act({ type = "open", overlay = "metadata_editor", kind = "track", id = library.tracks[1].id })
	App:act({ type = "metadataDraft", field = "track", value = "two" })
	App:act({ type = "metadataSave" })
	test.equal(App.services.metadata.task, nil, "nothing is written")
	test.truthy(App:overlay("metadata_editor") ~= nil, "the dialog stays open")
	fs.rmdir(folder)
end)
