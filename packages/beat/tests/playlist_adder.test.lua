-- The playlist adder: albums and tracks as two sections, a search over both, one hit per row, and
-- a trailing mark that stays inside the row it ends. It is the panel a manual playlist's + opens,
-- and the rows are drawn from the app's own list so a library too big to list is windowed.
local test = require("lde-test")
local wonderland = require("wonderland")
local elements = require("wonderland.element")
local fs = require("fs")
local paths = require("beat.paths")
local Library = require("beat.music.library")
local Taxonomy = require("beat.app.services.collections.taxonomy")
local App = require("beat.app")

local canRender = true
do
	local ok = pcall(function()
		wonderland.headless.new(function() return wonderland.div() end, { width = 8, height = 8 }):close()
	end)
	canRender = ok
end

local configDirectory = os.tmpname() .. "-beat-adder-config"
os.remove(configDirectory)
fs.mkdirAll(configDirectory)

local realDirectory = paths.directory
paths.directory = function() return configDirectory end

test.afterAll(function()
	paths.directory = realDirectory
	fs.rmdir(configDirectory)
end)

--- Two albums of two tracks, with titles no other row can be mistaken for.
---@return beat.Library
local function fixture()
	local library = Library.new("/beat-adder-fixtures")
	local albums = { "Amber", "Birch" }
	for albumAt = 1, 2 do
		local artist = "Artist " .. albums[albumAt]
		local dir = "/beat-adder-fixtures/" .. artist .. "/" .. albums[albumAt]
		for trackAt = 1, 2 do
			library:add(
				{
					format = "FLAC",
					sampleRate = 44100,
					channels = 2,
					duration = 120,
					hasPicture = false,
					tags = {
						title = albums[albumAt] .. " " .. (trackAt == 1 and "One" or "Two"),
						artist = artist,
						album = albums[albumAt],
						albumArtist = artist,
						track = trackAt
					}
				},
				{ path = dir .. "/" .. trackAt .. ".flac", dir = dir, name = trackAt .. ".flac", ext = "flac" }
			)
		end
	end
	return library
end

--- The app's own frame, with the adder open over an empty manual playlist.
---@return wonderland.Headless screen
---@return beat.Playlist playlist
---@return beat.Library library
local function openAdder()
	App:init({ scan = false })
	local library = fixture()
	App.services.library.current = library
	App.services.collections.taxonomy = Taxonomy.new()
	App.services.collections.save = function() end
	App.services.settings.values.root = "/beat-adder-fixtures"
	local playlist = assert(App.services.collections.taxonomy:addPlaylist("Mix", false))

	local screen = wonderland.headless.new(function(window, assets)
		App.window = window
		App.assets = assets
		App.services.covers:use(assets)
		return require("beat.app.shell").view(App, window)
	end, { width = 1200, height = 720, onMessage = function(message) App:act(message) end })
	App.layoutPlugin = screen.plugins.layout
	App.uiPlugin = screen.plugins.ui
	App.window = screen.window
	App.page = { kind = "playlist", id = playlist.id }
	App.persistedPageKey = App:keyOf(App.page)

	screen:draw()
	App:act({ type = "open", overlay = "playlist_adder", playlistId = playlist.id })
	screen:draw()
	return screen, playlist, library
end

---@param screen wonderland.Headless
local function closeAdder(screen)
	screen:close()
	App.services.playback.player:close()
end

--- The layout context the last frame solved.
---@param screen wonderland.Headless
---@return table
local function layoutContext(screen)
	local ctx
	for _, value in pairs(screen.plugins.layout.contexts) do ctx = value end
	return assert(ctx)
end

--- Every box drawn with one name, in absolute window coordinates.
---@param ctx table
---@param name string
---@return { x: number, y: number, width: number, height: number }[]
local function namedBoxes(ctx, name)
	local found = {}
	local function walk(index, parentX, parentY)
		local node = ctx.screen:node(index)
		local x, y = parentX + node.x, parentY + node.y
		local element = elements.pointers[node.element]
		if element ~= nil and elements.nameOf(element) == name then
			found[#found + 1] = { x = x, y = y, width = node.width, height = node.height }
		end
		for child = 0, node.childCount - 1 do
			local nextIndex = ctx.screen.childIndices[node.firstChild + child - 1]
			if nextIndex ~= nil then walk(nextIndex, x, y) end
		end
	end
	walk(ctx.root, 0, 0)
	return found
end

---@param boxes { x: number, y: number, width: number, height: number }[]
local function sortByY(boxes)
	table.sort(boxes, function(a, b) return a.y < b.y end)
	return boxes
end

--- The trailing mark of the row at a place in the list, and the row it belongs to.
---@param ctx table
---@param index number
---@return { x: number, y: number, width: number, height: number } trail
---@return { x: number, y: number, width: number, height: number } row
local function rowAndTrail(ctx, index)
	local rows = sortByY(namedBoxes(ctx, "playlistAdderRow"))
	local trails = sortByY(namedBoxes(ctx, "playlistAdderTrail"))
	local row, trail = rows[index], trails[index]
	assert(row ~= nil, "the adder drew no row " .. index)
	assert(trail ~= nil, "the adder drew no trailing mark " .. index)
	return trail, row
end

local function click(screen, box)
	screen:click(math.floor(box.x + box.width / 2), math.floor(box.y + box.height / 2))
end

test.skipIf(not canRender)("adds and removes one track at a time from the tracks section", function()
	local screen, playlist, library = openAdder()

	local ctx = layoutContext(screen)
	test.equal(#namedBoxes(ctx, "playlistAdderRow"), 2, "the album section lists the two albums")
	test.equal(#namedBoxes(ctx, "playlistAdderRow"), #namedBoxes(ctx, "playlistAdderTrail"))

	App:act({ type = "playlistAdderMode", value = "tracks" })
	screen:draw()
	ctx = layoutContext(screen)
	test.equal(#namedBoxes(ctx, "playlistAdderRow"), 4, "the tracks section lists the four tracks instead")

	local trail = rowAndTrail(ctx, 1)
	click(screen, trail)
	local tracks = App.services.collections:playlistTracks(playlist)
	test.equal(#tracks, 1, "one click adds one track, not its album")
	test.equal(tracks[1].title, library.tracks[1].title, "the row that was clicked is the track that went in")

	-- The row it added wears the check; the same hit takes that key back out of the list.
	screen:draw()
	ctx = layoutContext(screen)
	trail = rowAndTrail(ctx, 1)
	click(screen, trail)
	test.equal(#App.services.collections:playlistTracks(playlist), 0, "a checked row removes its track")

	closeAdder(screen)
end)

test.skipIf(not canRender)("searches albums and tracks separately and adds the match", function()
	local screen, playlist = openAdder()

	App:act({ type = "search", value = "Birch" })
	screen:draw()
	local ctx = layoutContext(screen)
	test.equal(#namedBoxes(ctx, "playlistAdderRow"), 1, "the album search leaves the one album")
	local trail = rowAndTrail(ctx, 1)
	click(screen, trail)
	test.equal(#App.services.collections:playlistTracks(playlist), 2, "the album added its two tracks")

	App:act({ type = "playlistAdderMode", value = "tracks" })
	App:act({ type = "search", value = "Amber One" })
	screen:draw()
	ctx = layoutContext(screen)
	test.equal(#namedBoxes(ctx, "playlistAdderRow"), 1, "the track search leaves the one track")
	trail = rowAndTrail(ctx, 1)
	click(screen, trail)
	local tracks = App.services.collections:playlistTracks(playlist)
	test.equal(#tracks, 3, "the matching track joined the album's tracks")
	local added = false
	for _, track in ipairs(tracks) do
		if track.title == "Amber One" then added = true end
	end
	test.truthy(added, "the track the search showed is the one that went in")

	App:act({ type = "search", value = "nothing matches this" })
	screen:draw()
	test.equal(#namedBoxes(layoutContext(screen), "playlistAdderRow"), 0, "a query with no answer draws no rows")

	closeAdder(screen)
end)

test.skipIf(not canRender)("keeps every trailing mark inside the row that ends it", function()
	local screen = openAdder()
	local ctx = layoutContext(screen)

	for index = 1, 2 do
		local trail, row = rowAndTrail(ctx, index)
		test.truthy(trail.x >= row.x, "the mark starts inside the row's left edge")
		test.truthy(trail.x + trail.width <= row.x + row.width, "the mark ends inside the row's right edge")
		test.truthy(trail.y >= row.y, "the mark starts below the row's top edge")
		test.truthy(trail.y + trail.height <= row.y + row.height, "the mark ends above the row's bottom edge")
	end

	closeAdder(screen)
end)
