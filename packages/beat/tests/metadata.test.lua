-- Editing tags from the dialog: only the fields changed are written, the file gets them, and the
-- track takes its new place in the library and in the queue without a rescan.
local test = require("lde-test")
local fs = require("fs")
local audio = require("treble.audio")
local paths = require("beat.paths")
local Library = require("beat.music.library")
local Queue = require("beat.app.services.playback.queue")
local App = require("beat.app")
local element = require("wonderland.element")
local style = require("wonderland.style")
local ui = require("beat-ui")

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

---@param parent wonderland.Element
---@param at number
---@return wonderland.Element
local function childAt(parent, at)
	local child = element.at(parent.childFirst)
	for _ = 2, at do child = element.at(child.nextSibling) end
	return child
end

--- The field rows of an open editor, as the view builds them: the dialog's panel holds the heading
--- first, then one row per field. The element arena is a frame, so this is asked once per frame.
---@param overlay beat.OverlayInstance
---@return wonderland.Element[], beat.Theme
local function fieldRows(overlay)
	local editor = require("beat.app.overlays.metadata_editor")
	element.beginFrame()
	local root = editor.view(App, overlay, { width = 1200, height = 720 })
	local panel = childAt(root, 1)
	local rows = {}
	for at = 1, #overlay.state.fields do rows[at] = childAt(panel, at + 1) end
	return rows, App.services.appearance.theme
end

--- The glyph string a field row's icon column draws.
---@param row wonderland.Element
---@return string?
local function glyphOf(row)
	local iconColumn = childAt(row, 1)
	return element.textOf(childAt(childAt(iconColumn, 1), 1))
end

--- The icon component falls back to the GitHub mark for a name the face does not have; a glyph
--- equal to this one is a misspelling rather than an icon.
---@param theme beat.Theme
---@return string?
local function fallbackGlyph(theme)
	local ctx = App:ui({ width = 1200, height = 720 })
	return element.textOf(childAt(ui.icon(ctx, {
		name = "github",
		size = theme:px(16),
		colour = theme:color("muted")
	}), 1))
end

test.it("each track field leads with a glyph in one fixed column", function()
	App:init({ scan = false })
	local folder, file = copyFixture()
	local library = Library.new(folder)
	library:add(assert(audio.inspect(file)), { path = file, dir = folder, name = "song.opus", ext = "opus" }, nil)
	library:finish()
	App.services.library.current = library
	App:act({ type = "open", overlay = "metadata_editor", kind = "track", id = library.tracks[1].id })

	local overlay = assert(App:overlay("metadata_editor"))
	local rows, theme = fieldRows(overlay)
	local glyphs = {}
	local fieldWidth = nil
	local fallback = fallbackGlyph(theme)
	for at, field in ipairs(overlay.state.fields) do
		local row = rows[at]
		local iconColumn = childAt(row, 1)
		local icon = childAt(iconColumn, 1)

		local glyph = assert(glyphOf(row), "a glyph on " .. field.key)
		test.truthy(#glyph > 0, field.key .. " has a glyph")
		test.truthy(glyph ~= fallback, field.key .. " names a glyph the face has")
		glyphs[field.key] = glyph

		local box = style.at(iconColumn.baseStyle)
		test.equal(box.widthUnit, style.ABS, field.key .. " icon is a fixed square")
		test.equal(box.wantWidth, theme:px(16), field.key .. " icon is the menu's size")
		test.equal(box.heightUnit, style.ABS)
		test.equal(box.wantHeight, theme:px(16))

		local label = style.at(childAt(row, 2).baseStyle)
		test.equal(label.wantWidth, theme:px(96), "the label column is the same on every row")

		local inputWidth = style.at(childAt(row, 3).baseStyle).wantWidth
		if fieldWidth == nil then
			fieldWidth = inputWidth
		else
			test.equal(inputWidth, fieldWidth, "the input starts at the same place on every row")
		end

		-- The glyph box itself is the icon the component drew, not an empty square.
		test.equal(style.at(icon.baseStyle).wantWidth, theme:px(16), field.key .. " glyph fills its square")
	end

	test.equal(glyphs.track, glyphs.disc, "the two numbers share the list mark")
	test.truthy(glyphs.title ~= glyphs.artist, "each field has its own mark")
	test.truthy(glyphs.artist ~= glyphs.album)
	test.truthy(glyphs.album ~= glyphs.albumArtist)
	test.truthy(glyphs.date ~= glyphs.genre)

	fs.rmdir(folder)
end)

test.it("the album editor's fields lead with the same glyph column", function()
	App:init({ scan = false })
	local folder, file = copyFixture()
	local library = Library.new(folder)
	library:add(assert(audio.inspect(file)), { path = file, dir = folder, name = "song.opus", ext = "opus" }, nil)
	library:finish()
	App.services.library.current = library
	local albumId = library.tracks[1].albumId
	App:act({ type = "open", overlay = "metadata_editor", kind = "album", id = albumId })

	local overlay = assert(App:overlay("metadata_editor"))
	local rows, theme = fieldRows(overlay)
	local fallback = fallbackGlyph(theme)
	test.equal(#rows, #overlay.state.fields, "the album form has one row per field")
	for at, field in ipairs(overlay.state.fields) do
		local iconColumn = childAt(rows[at], 1)
		local glyph = assert(glyphOf(rows[at]), "a glyph on " .. field.key)
		test.truthy(glyph ~= fallback, field.key .. " names a glyph the face has")
		test.equal(style.at(iconColumn.baseStyle).wantWidth, theme:px(16), field.key .. " icon is the menu's size")
	end

	fs.rmdir(folder)
end)
