-- The app builds and draws every page with no window. The core has its own tests; this is the
-- smoke test that says the screens the core feeds still come out as elements.
local test = require("lde-test")
local wonderland = require("wonderland")
local core = require("beat-core")
local App = require("beat.app")
local TagStore = require("beat.app.tag_store")
local fs = require("fs")
local style = require("wonderland.style")

local canRender = true
	do
	local ok = pcall(function()
		wonderland.headless.new(function() return wonderland.div() end, { width = 8, height = 8}):close()
	end)
	canRender = ok
end

-- The app writes settings, tags and the library cache through `core.settings.directory`. A test
-- that finishes a scan would otherwise replace the user's library cache with its fixtures -- and
-- the next real launch, whose root no longer matched, would scan the whole folder again.
local configDirectory = os.tmpname() .. "-beat-config"
os.remove(configDirectory)
fs.mkdirAll(configDirectory)

local realDirectory = core.settings.directory
core.settings.directory = function() return configDirectory end

test.afterAll(function()
	core.settings.directory = realDirectory
	fs.rmdir(configDirectory)
end)

local function fixture()
	local library = core.Library.new("/beat-fixtures")
	for albumAt = 1, 3 do
			local artist = "Artist " .. albumAt
			local dir = "/beat-fixtures/" .. artist .. "/Album " .. albumAt
			for trackAt = 1, 3 do
					library:add({
					format = "FLAC",
					sampleRate = 44100,
					channels = 2,
					duration = 180,
					hasPicture = false,
					tags = {
					title = "Track " .. trackAt,
					artist = artist,
					album = "Album " .. albumAt,
					albumArtist = artist,
					track = trackAt,
					},
					}, {
					path = dir .. "/" .. trackAt .. ".flac",
					dir = dir,
					name = trackAt .. ".flac",
					ext = "flac",
					}, nil)
				end
		end
	library:finish()
	return library
end

test.skipIf(not canRender)("draws every page the app has", function()
	App:init({ scan = false})
	App.settings.root = "/beat-fixtures"
	local library = fixture()
	App.library = library
	App.scan = nil
	App.player.queue = core.Queue.new(library.albums[1].tracks, 1, { repeatMode = "all"})
	App.player.loaded = true
	local playhead = 12
	App.player.player = {
	isPlaying = function() return true end,
	position = function() return playhead end,
	duration = function() return 180 end,
	play = function() end,
	pause = function() end,
	seek = function() end,
	setVolume = function() end,
	update = function() end,
	close = function() end,
	}

	local screen = wonderland.headless.new(function(window, assets)
		App.window = window
		App.assets = assets
		App.covers:use(assets)
		return require("beat.app.pages").view(App, window)
	end, { width = 1200, height = 720})

	local pages = {
	{ kind = "home"},
	{ kind = "library"},
	{ kind = "album", id = library.albums[1].id},
	{ kind = "artist", id = library.artists[1].id},
	{ kind = "search"},
	{ kind = "playlists"},
	{ kind = "settings"},
	{ kind = "folders"},
	}

	for _, page in ipairs(pages) do
			App.page = page
			App.search = page.kind == "search" and "track" or ""
			screen:draw()
			test.truthy(screen.window.width > 0)
		end

	App.search = "night"
	App.page = { kind = "searchAll", category = "tracks"}
	screen:draw()
	test.truthy(true, "the see-all tracks page draws")
	App.search = ""

	App.expanded = true
	App.motion:set("nowPlaying", 1)
	screen:draw()
	test.truthy(true, "the expanded now playing view draws")

	App.expanded = false
	App.page = { kind = "library"}
	App.settings.view = "list"
	screen:draw()
	test.truthy(true, "the library list view draws")
	App.settings.view = "grid"

	local styles = style.count()
	for at = 1, 20 do
			playhead = 12 + at / 10
			screen:draw()
		end
	test.equal(style.count(), styles, "a moving playhead does not intern a style a frame")

	screen:close()
	App.player:close()
end)

test.skipIf(not canRender)("reuses the page-transition styles", function()
	App:init({ scan = false})
	App.settings.root = "/beat-fixtures"
	local library = fixture()
	App.library = library
	App.scan = nil
	App.page = { kind = "home"}
	App.motion.reduce = false

	local screen = wonderland.headless.new(function(window, assets)
		App.window = window
		App.assets = assets
		App.covers:use(assets)
		return require("beat.app.pages").view(App, window)
	end, { width = 1200, height = 720})

	screen:draw()
	local started = wonderland.time.now()
	local function slide()
		for step = 0, 64 do
				App.transition = { start = started - step / 64 * 0.28, direction = 1}
				screen:draw()
			end
	end
	slide()
	local warm = style.count()
	slide()
	test.equal(style.count(), warm, "a transition does not intern a style every frame")

	screen:close()
	App.player:close()
end)

test.it("wakes the ticker when navigation starts an animation", function()
	local ticker = App.ticker
	App.page = { kind = "home"}
	App.ticker = { due = 99}
	App.transition = { start = wonderland.time.now(), direction = 1}
	App:go({ kind = "home"})
	test.equal(App.ticker.due, 0, "a repeat click wakes a transition already in flight")
	App.ticker.due = 99
	App:go({ kind = "settings"})
	test.equal(App.ticker.due, 0, "a page transition asks for its first frame now")
	App.ticker = ticker
end)

test.it("opens the About link through the platform opener", function()
	local links = require("beat.app.links")
	local open, opened = links.open, nil
	links.open = function(url)
		opened = url
		return true
	end

	App:act({ type = "openURL", url = "https://github.com/bycruz/beat"})
	links.open = open
	test.equal(opened, "https://github.com/bycruz/beat", "the GitHub button asks the desktop to open its URL")
end)

test.it("logs an error toast where the app keeps its files", function()
	App:init({ scan = false })
	App:toast("a test failure", "error")

	local logFile = core.settings.directory() .. "/beat.log"
	local contents = fs.read(logFile)

	test.truthy(contents ~= nil, "the error is written to beat.log")
	test.truthy(contents and contents:find("a test failure", 1, true) ~= nil,
		"and it names the error")
end)

test.it("keeps an error toast under the pointer", function()
	App:init({ scan = false })
	local now = wonderland.time.now()

	App:toast("still here", "error")
	local toast = App.toasts[#App.toasts]
	toast.rect = { x = 100, y = 100, width = 320, height = 48 }
	toast.expires = now - 1

	local oldWindow, oldLayout = App.window, App.layoutPlugin
	App.window = { width = 1200, height = 720 }
	App.layoutPlugin = {
		contexts = {
			[App.window] = { pointer = { x = 110, y = 110, pressed = false } },
		},
	}
	App:tick(now, App.window)
	App.window, App.layoutPlugin = oldWindow, oldLayout

	test.equal(#App.toasts, 1, "the toast was not removed")
	test.greater(App.toasts[1].expires, now, "its expiry moved forward")
end)

test.skipIf(not canRender)("focuses the new tag field for typing", function()
	App:init({ scan = false})
	App.settings.root = "/beat-fixtures"
	App.taxonomy = core.Taxonomy.new()
	App.page = { kind = "playlists"}
	App.search = ""
	local previousLayout = App.layoutPlugin

	local screen
	screen = wonderland.headless.new(function(window, assets)
		App.window = window
		App.assets = assets
		App.covers:use(assets)
		return require("beat.app.pages").view(App, window)
	end, {
	width = 1200,
	height = 720,
	onMessage = function(message)
		App:act(message)
		screen:draw()
	end,
	})
	App.layoutPlugin = screen:getPlugin("layout")
	App.layoutPlugin.clipboard = {
	text = "",
	setText = function(self, value) self.text = value end,
	getText = function(self) return self.text end,
	}
	screen:draw()

	App:act({ type = "openTagDialog"})
	screen:draw()
	test.equal(App.layoutPlugin:getFocusedId(screen.window), "newTag")
	local function key(name, ctrl)
		screen:event({
		name = "keyPress",
		key = name,
		modifiers = ctrl and { ctrl = true} or {},
		window = screen.window,
		})
		screen:draw()
	end
	key("x")
	test.equal(App.tagDraft, "x", "typing lands in the tag name without a click")
	key("backspace")
	key("H")
	key("i")
	key("g")
	key("h")
	key("a", true)
	local _, _, _, from, to = App.layoutPlugin:getCaret(screen.window)
	test.equal(from, 0)
	test.equal(to, 4)
	key("c", true)
	test.equal(App.layoutPlugin.clipboard.text, "High")
	key("x", true)
	test.equal(App.tagDraft, "")
	key("v", true)
	test.equal(App.tagDraft, "High")

	local elements = require("wonderland.element")
	local ctx
	for _, value in pairs(App.layoutPlugin.contexts) do ctx = value end
	local fieldX, fieldY, fieldWidth, fieldHeight
	local function findField(index, parentX, parentY)
		local node = ctx.screen:node(index)
		local x, y = parentX + node.x, parentY + node.y
		local element = elements.pointers[node.element]
		if element ~= nil and elements.nameOf(element) == "newTag" then
			fieldX, fieldY, fieldWidth, fieldHeight = x, y, node.width, node.height
		end
		for child = 0, node.childCount - 1 do
				local nextIndex = ctx.screen.childIndices[node.firstChild + child - 1]
				if nextIndex ~= nil then findField(nextIndex, x, y) end
			end
	end
	findField(ctx.root, 0, 0)
	test.truthy(fieldX ~= nil and fieldWidth > 0)
	if fieldX ~= nil then
		local y = fieldY + fieldHeight / 2
		screen:event({ name = "mousePress", window = screen.window, x = fieldX + 12, y = y, button = 1})
		screen:event({ name = "mouseMove", window = screen.window, x = fieldX + fieldWidth - 20, y = y})
		screen:event({ name = "mouseRelease", window = screen.window, x = fieldX + fieldWidth - 20,
		y = y, button = 1})
		screen:draw()
		local _, _, _, mouseFrom, mouseTo = App.layoutPlugin:getCaret(screen.window)
		test.equal(mouseFrom, 0)
		test.equal(mouseTo, 4, "a drag selects the whole name")

		-- A single click clears that selection; two presses in the same place select the word.
		screen:event({ name = "mousePress", window = screen.window, x = fieldX + 40, y = y, button = 1})
		screen:event({ name = "mouseRelease", window = screen.window, x = fieldX + 40, y = y, button = 1})
		screen:draw()
		local _, _, _, singleFrom, singleTo = App.layoutPlugin:getCaret(screen.window)
		test.equal(singleFrom, nil)
		test.equal(singleTo, nil, "a click leaves the caret without a selection")
		for _ = 1, 2 do
				screen:event({ name = "mousePress", window = screen.window, x = fieldX + 12, y = y, button = 1})
				screen:event({ name = "mouseRelease", window = screen.window, x = fieldX + 12, y = y, button = 1})
			end
		screen:draw()
		local _, _, _, doubleFrom, doubleTo = App.layoutPlugin:getCaret(screen.window)
		test.equal(doubleFrom, 0)
		test.equal(doubleTo, 4, "a double click selects the word")
	end

	screen:close()
	App.layoutPlugin = previousLayout
	App.player:close()
end)

test.skipIf(not canRender)("opens an empty playlist and adds an album", function()
	App:init({ scan = false})
	local library = fixture()
	local screen
	screen = wonderland.headless.new(function(window, assets)
		App.window = window
		App.assets = assets
		App.covers:use(assets)
		return require("beat.app.pages").view(App, window)
	end, { width = 1200, height = 720})
	App.taxonomy = core.Taxonomy.new()
	App.saveTaxonomy = function() end
	App.library = library
	local playlist = assert(App.taxonomy:addPlaylist("Empty", false))
	App.page = { kind = "playlist", id = playlist.id}

	screen:draw()
	test.truthy(screen.window.width > 0)
	App:act({ type = "openPlaylistAdder", id = playlist.id})
	screen:draw()
	App:act({ type = "playlistAddAlbum", id = library.albums[1].id})
	screen:draw()
	test.equal(#App.taxonomy:playlistTracks(playlist, library), 3,
	"an album can be added from the empty playlist")

	App:act({ type = "closePlaylistAdder"})
	screen:close()
	App.player:close()
end)

test.it("starts a playlist from its page with shuffle", function()
	App:init({ scan = false})
	local library = fixture()
	App.library = library
	App.taxonomy = core.Taxonomy.new()
	App.saveTaxonomy = function() end
	local playlist = assert(App.taxonomy:addPlaylist("Mix", false))
	App.taxonomy:setPlaylistAlbum(playlist, library.albums[1])

	local captured
	local real = App.player
	App.player = {
	playTracks = function(_, tracks, index, opts)
		captured = { tracks = tracks, index = index, opts = opts}
	end,
	}
	App:act({ type = "playPlaylist", id = playlist.id, shuffle = true})
	App.player = real

	test.truthy(captured ~= nil, "the page starts the playlist")
	test.equal(#captured.tracks, #library.albums[1].tracks)
	test.equal(captured.index, 1)
	test.equal(captured.opts.shuffle, true, "the shuffle control reaches the queue")
	test.equal(captured.opts.source, "playlist:" .. tostring(playlist.id))
	real:close()
end)

test.it("records a listen when playback starts a track", function()
	App:init({ scan = false})
	local library = fixture()
	App.library = library
	App.taxonomy = core.Taxonomy.new()
	App.saveTaxonomy = function() end
	App.lastListenedTrackId = nil
	App.player.queue = core.Queue.new(library.albums[1].tracks, 1, { source = "playlist:9"})
	App.player.loaded = true
	App.player.player = {
	isPlaying = function() return true end,
	position = function() return 1 end,
	duration = function() return 180 end,
	play = function() end,
	pause = function() end,
	seek = function() end,
	setVolume = function() end,
	update = function() end,
	close = function() end,
	}

	App:tick(10, { width = 1200, height = 720, shouldRedraw = false})
	local track = library.albums[1].tracks[1]
	test.equal(App.taxonomy.metrics.tracks[track.path].count, 1)
	test.equal(App.taxonomy.metrics.albums[library.albums[1].key].count, 1)
	test.equal(App.taxonomy.metrics.playlists[9].count, 1)
	App.player:close()
end)

test.it("renames and deletes tags without changing their ids", function()
	App:init({ scan = false})
	App.taxonomy = core.Taxonomy.new()
	App.saveTaxonomy = function() end
	local tag = assert(App.taxonomy:addTag("Focus"))
	local auto = App.taxonomy.playlists[1]
	App:act({ type = "editTag", id = tag.id})
	App:act({ type = "tagEditDraft", value = "Deep Focus"})
	App:act({ type = "renameTag"})
	test.equal(App.taxonomy.tagById[tag.id].name, "Deep Focus")
	test.equal(auto.name, "Deep Focus")
	test.equal(App.tagEditId, nil)

	App:act({ type = "deleteTag", id = tag.id})
	test.equal(App.taxonomy.tagById[tag.id], nil)
	test.equal(App.taxonomy:playlist(auto.id), nil)
end)

test.it("deletes a playlist from its row menu", function()
	App:init({ scan = false})
	App.taxonomy = core.Taxonomy.new()
	App.saveTaxonomy = function() end
	local playlist = assert(App.taxonomy:addPlaylist("Temporary", false))
	App:act({ type = "playlistMenu", id = playlist.id, x = 20, y = 20})
	test.truthy(App.playlistMenu ~= nil, "the row opens a playlist menu")
	App:act({ type = "deletePlaylist", id = playlist.id})
	test.equal(App.taxonomy:playlist(playlist.id), nil)
	test.equal(App.playlistMenu, nil, "deleting closes the menu")
end)

test.it("confirms deleting a tag only when it has been applied", function()
	App:init({ scan = false})
	App.taxonomy = core.Taxonomy.new()
	App.saveTaxonomy = function() end

	local unused = assert(App.taxonomy:addTag("Unused"))
	App:act({ type = "deleteTag", id = unused.id})
	test.equal(App.taxonomy.tagById[unused.id], nil, "an unused tag goes immediately")
	test.equal(App.tagDeleteId, nil)

	local used = assert(App.taxonomy:addTag("Used"))
	local auto = App.taxonomy.playlists[#App.taxonomy.playlists]
	App.taxonomy:setTag("/music/a.flac", used.id, true)
	test.equal(used.count, 1)
	App:act({ type = "deleteTag", id = used.id})
	test.truthy(App.taxonomy.tagById[used.id] ~= nil, "a used tag waits for confirmation")
	test.equal(App.tagDeleteId, used.id)

	App:act({ type = "cancelDeleteTag"})
	test.truthy(App.taxonomy.tagById[used.id] ~= nil, "cancelling keeps the tag")
	test.equal(App.tagDeleteId, nil)

	App:act({ type = "deleteTag", id = used.id})
	App:act({ type = "confirmDeleteTag"})
	test.equal(App.taxonomy.tagById[used.id], nil, "confirming removes the used tag")
	test.equal(App.taxonomy:playlist(auto.id), nil, "and its automatic playlist")
	test.equal(App.tagDeleteId, nil)
end)

test.it("filters search results with selected tags", function()
	App:init({ scan = false})
	local library = fixture()
	App.library = library
	App.taxonomy = core.Taxonomy.new()
	local high = assert(App.taxonomy:addTag("High Energy"))
	App.taxonomy:setTag(library.albums[1].tracks[1].path, high.id, true)

	App.tagFilter = { [high.id] = true}
	App.tagFilterMatch = "all"
	local albums, artists, tracks = App:searchResults("Artist")
	test.equal(#tracks, 1, "only the tagged track survives")
	test.equal(tracks[1].albumId, library.albums[1].id)
	test.equal(#albums, 1, "an album survives when one of its tracks matches")
	test.equal(#artists, 1, "an artist survives when one of its tracks matches")

	local late = assert(App.taxonomy:addTag("Late Night"))
	App.taxonomy:setTag(library.albums[1].tracks[2].path, late.id, true)
	App.tagFilter = { [high.id] = true, [late.id] = true}
	App.tagFilterMatch = "all"
	_, _, tracks = App:searchResults("Artist")
	test.equal(#tracks, 0, "all tags means a track must carry both")
	App.tagFilterMatch = "any"
	_, _, tracks = App:searchResults("Artist")
	test.equal(#tracks, 2, "any tag means either tag qualifies")

	App.tagFilter = {}
	albums, artists, tracks = App:searchResults("Artist")
	test.equal(#tracks, 9, "clearing the filter restores the search")
end)

test.it("persists tags and playlists beside settings", function()
	local dir = os.tmpname() .. "-beat-tags"
	fs.mkdirAll(dir)
	local taxonomy = core.Taxonomy.new()
	local high = assert(taxonomy:addTag("High Energy"))
	local smart = assert(taxonomy:addPlaylist("High", true, { high.id}, "all"))
	local manual = assert(taxonomy:addPlaylist("Manual", false))
	taxonomy:setTag("/music/a.flac", high.id, true)
	taxonomy:setPlaylistTrack(manual, "/music/b.flac", true)

	local saved = TagStore.save(taxonomy, dir)
	test.truthy(saved)
	local loaded = TagStore.load(dir)
	test.equal(#loaded:visibleTags(), 1)
	test.truthy(loaded:isTagged("/music/a.flac", loaded:visibleTags()[1].id))
	test.equal(#loaded:playlistTracks(loaded:playlist(smart.id),
	{ tracks = {{ path = "/music/a.flac"}}}), 1)
	test.equal(#loaded:playlistTracks(loaded:playlist(manual.id),
	{ tracks = {{ path = "/music/b.flac"}}}), 1)
	fs.rmdir(dir)
end)

test.it("creates tags and playlists from the app actions", function()
	App:init({ scan = false})
	local library = fixture()
	App.library = library
	App.taxonomy = core.Taxonomy.new()
	App.saveTaxonomy = function() end

	App:act({ type = "openTagDialog"})
	App:act({ type = "tagDraft", value = "High Energy"})
	App:act({ type = "createTag"})
	local tag = App.taxonomy:visibleTags()[1]
	test.truthy(tag ~= nil)
	test.equal(tag.name, "High Energy")
	test.falsy(App.tagDialogOpen, "creating a tag closes its dialog")

	App:act({ type = "openPlaylistDialog", smart = true})
	App:act({ type = "playlistDraft", value = "Night"})
	App:act({ type = "playlistDraftTag", id = tag.id})
	App:act({ type = "createPlaylist"})
	local smart
	for _, playlist in ipairs(App.taxonomy.playlists) do
			if playlist.name == "Night" then smart = playlist end
		end
	test.truthy(smart ~= nil)
	test.equal(smart.name, "Night")
	test.truthy(smart.smart)
	test.equal(#smart.tagIds, 1)

	App.taxonomy:setTag(library.albums[1].tracks[1].path, tag.id, true)
	test.equal(#App.taxonomy:playlistTracks(smart, library), 1, "the smart playlist follows the tag")

	App:act({ type = "openPlaylistDialog", smart = false})
	App:act({ type = "playlistDraft", value = "Favourites"})
	App:act({ type = "createPlaylist"})
	local manual
	for _, playlist in ipairs(App.taxonomy.playlists) do
			if playlist.name == "Favourites" then manual = playlist end
		end
	test.truthy(manual ~= nil)
	App.playlistPicker = { kind = "album", id = library.albums[2].id}
	App:act({ type = "addToPlaylist", playlistId = manual.id})
	test.equal(#App.taxonomy:playlistTracks(manual, library), 3, "an album is added by hand")
	App.playlistPicker = { kind = "track", id = library.albums[1].tracks[1].id}
	App:act({ type = "addToPlaylist", playlistId = manual.id})
	test.equal(#App.taxonomy:playlistTracks(manual, library), 4, "a track is added by hand")
end)

test.skipIf(not canRender)("types into the search field and opens search", function()
	App:init({ scan = false})
	App.settings.root = "/beat-fixtures"
	App.library = fixture()
	App.scan = nil
	App.page = { kind = "home"}
	App.search = ""

	local screen
	screen = wonderland.headless.new(function(window, assets)
		App.window = window
		App.assets = assets
		App.covers:use(assets)
		return require("beat.app.pages").view(App, window)
	end, {
	width = 1200,
	height = 720,
	onMessage = function(message)
		App:act(message)
		screen:draw()
	end,
	})
	local previousLayout = App.layoutPlugin
	App.layoutPlugin = screen:getPlugin("layout")

	screen:draw()
	screen:click(500, 35)

	local function key(name)
		screen:event({ name = "keyPress", key = name, modifiers = {}, window = screen.window})
	end

	key("n")
	test.equal(App.layoutPlugin:getFocusedId(screen.window), "search", "the first key keeps the search field")
	key("i")
	key("g")
	screen:draw()

	test.equal(App.search, "nig")
	test.equal(App.page.kind, "search")
	test.equal(App.layoutPlugin:getFocusedId(screen.window), "search")

	screen:close()
	App.layoutPlugin = previousLayout
	App.player:close()
end)

test.skipIf(not canRender)("windows the library as it scrolls", function()
	App:init({ scan = false})
	App.settings.root = "/beat-fixtures"
	local library = core.Library.new("/beat-fixtures")
	for albumAt = 1, 40 do
			local name = string.format("Album %03d", albumAt)
			for trackAt = 1, 2 do
					library:add({
					format = "WAV",
					duration = 180,
					tags = { title = name .. " " .. trackAt, artist = "Artist", album = name,
					albumArtist = "Artist", track = trackAt},
					}, {
					path = "/beat-fixtures/" .. albumAt .. "/" .. trackAt .. ".wav",
					dir = "/beat-fixtures/" .. albumAt,
					name = trackAt .. ".wav",
					})
				end
		end
	library:finish()
	App.library = library
	App.scan = nil
	App.settings.sort = "title"
	App.settings.view = "grid"
	App.settings.sidebarWidth = 264
	App.settings.sidebarCollapsed = false
	App.page = { kind = "library"}

	local screen = wonderland.headless.new(function(window, assets)
		App.window = window
		App.assets = assets
		App.covers:use(assets)
		return require("beat.app.pages").view(App, window)
	end, { width = 1200, height = 720})

	local elements = require("wonderland.element")
	local function albumTitles()
		local layout = screen:getPlugin("layout")
		local ctx
		for _, value in pairs(layout.contexts) do ctx = value end
		local tree = ctx.screen
		local found = {}
		local function walk(index, parentX, parentY)
			local node = tree:node(index)
			local x, y = parentX + node.x, parentY + node.y
			local element = elements.pointers[node.element]
			if element ~= nil and element.text ~= 0 then
				local value = elements.strings[element.text]
				if value:match("^Album %d+$") and x > 290 then found[#found + 1] = { text = value, x = x, y = y} end
			end
			for child = 0, node.childCount - 1 do
					local nextIndex = tree.childIndices[node.firstChild + child - 1]
					if nextIndex ~= nil then walk(nextIndex, x, y) end
				end
		end
		walk(ctx.root, 0, 0)
		table.sort(found, function(a, b)
			if a.y ~= b.y then return a.y < b.y end
			return a.x < b.x
		end)
		local values = {}
		for _, entry in ipairs(found) do values[#values + 1] = entry.text end
		return values
	end

	screen:draw()
	local before = albumTitles()
	test.truthy(#before > 0, "the first window holds albums")
	test.truthy(before[1]:match("^Album %d+$"), "the first window holds album titles")

	App:act({ type = "scroll", to = 1200})
	screen:draw()
	local after = albumTitles()
	test.truthy(#after > 0, "the next window holds albums")
	test.truthy(after[1] ~= before[1], "the visible slice moved to the scroll offset")
	test.truthy(after[1] ~= "Album 001", "the first album scrolled out of the window")

	test.truthy(App.scrollMax ~= nil and App.scrollMax > 0, "the library publishes a scroll limit")
	App:act({ type = "scroll", to = 1000000})
	test.equal(App.scroll[App:pageKey()], App.scrollMax, "the library stops at its last row")

	screen:close()
	App.player:close()
end)

test.it("switches to the phone shell at narrow widths", function()
	App:init({ scan = false})
	local pages = require("beat.app.pages")
	test.truthy(pages.mobile(App, 390))
	test.equal(pages.sidebarWidth(App, 390), 0, "the rail is gone")
	test.equal(pages.pad(App, 390), App.theme:space(16))
	test.equal(pages.bottomHeight(App, 390), App.theme:px(58), "the bottom tabs fit")

	App.player.queue = core.Queue.new(fixture().albums[1].tracks, 1)
	test.equal(pages.bottomHeight(App, 390), App.theme:px(64 + 58),
	"a track adds the mini player above the tabs")
end)

test.skipIf(not canRender)("draws the phone shell and switches tabs", function()
	App:init({ scan = false})
	App.settings.root = "/beat-fixtures"
	App.settings.sidebarWidth = 264
	App.settings.sidebarCollapsed = false
	local library = fixture()
	App.library = library
	App.scan = nil
	App.page = { kind = "home"}
	App.search = ""

	local screen = wonderland.headless.new(function(window, assets)
		App.window = window
		App.assets = assets
		App.covers:use(assets)
		return require("beat.app.pages").view(App, window)
	end, { width = 390, height = 844})
	screen:draw()

	-- The second row of the phone shell is the tab bar; Search is the third of four tabs.
	local message = screen:event({
	name = "mousePress",
	window = screen.window,
	x = 243,
	y = 815,
	button = 1,
	})
	test.truthy(message ~= nil, "the bottom tab is a touch target")
	App:act(message)
	test.equal(App.page.kind, "search", "the tab switches the page")
	screen:draw()

	screen:close()
	App.player:close()
end)

test.it("orders sidebar playlists by their latest play", function()
	App:init({ scan = false})
	local library = fixture()
	App.library = library
	App.taxonomy = core.Taxonomy.new()
	local first = assert(App.taxonomy:addPlaylist("First", false))
	local second = assert(App.taxonomy:addPlaylist("Second", false))
	local third = assert(App.taxonomy:addPlaylist("Third", false))
	local fourth = assert(App.taxonomy:addPlaylist("Fourth", false))
	App.taxonomy:recordListen(library.albums[1].tracks[1], library, second.id, 300)
	App.taxonomy:recordListen(library.albums[2].tracks[1], library, first.id, 200)
	App.taxonomy:recordListen(library.albums[3].tracks[1], library, third.id, 100)

	local recent = App:recentPlaylists(3)
	test.equal(#recent, 3, "the sidebar keeps three shortcuts")
	test.equal(recent[1].id, second.id, "the latest playlist comes first")
	test.equal(recent[2].id, first.id)
	test.equal(recent[3].id, third.id)
	test.falsy(fourth == nil, "the never-played playlist exists but does not make the cut")
end)

test.skipIf(not canRender)("shows a sidebar playlist name only in its hover tooltip", function()
	App:init({ scan = false})
	App.settings.root = "/beat-fixtures"
	App.settings.sidebarWidth = 264
	App.settings.sidebarCollapsed = false
	local library = fixture()
	App.library = library
	App.scan = nil
	App.page = { kind = "home"}
	App.taxonomy = core.Taxonomy.new()
	local playlist = assert(App.taxonomy:addPlaylist("Night Mix", false))

	local screen = wonderland.headless.new(function(window, assets)
		App.window = window
		App.assets = assets
		App.covers:use(assets)
		return require("beat.app.pages").view(App, window)
	end, { width = 1200, height = 720})

	local elements = require("wonderland.element")
	local layout = screen:getPlugin("layout")
	local function hasText(value)
		local ctx
		for _, context in pairs(layout.contexts) do ctx = context end
		local tree = ctx.screen
		local found = false
		local function walk(index)
			local node = tree:node(index)
			local element = elements.pointers[node.element]
			if element ~= nil and element.text ~= 0 and elements.strings[element.text] == value then
				found = true
			end
			if not found then
				for child = 0, node.childCount - 1 do
						local nextIndex = tree.childIndices[node.firstChild + child - 1]
						if nextIndex ~= nil then walk(nextIndex) end
					end
			end
		end
		walk(ctx.root)
		return found
	end

	screen:draw()
	test.falsy(hasText("Night Mix"), "the row itself keeps the name hidden")

	local message
	for y = 100, 500, 4 do
			local candidate = screen:event({
			name = "mouseMove",
			window = screen.window,
			x = 60,
			y = y,
			})
			if candidate ~= nil and candidate.type == "hoverPlaylist" and candidate.id == playlist.id then
				message = candidate
				break
			end
		end
	test.truthy(message ~= nil, "the sidebar row answers the pointer")
	test.equal(message.type, "hoverPlaylist", "the sidebar row answers the pointer")
	test.equal(message.id, playlist.id)
	App:act(message)
	screen:draw()
	test.truthy(hasText("Night Mix"), "the tooltip names the playlist under the pointer")

	message = screen:event({
	name = "mouseMove",
	window = screen.window,
	x = 800,
	y = 500,
	})
	test.equal(message.type, "hoverPlaylist")
	test.equal(message.id, nil, "the page clears the tooltip when the pointer leaves")
	App:act(message)
	screen:draw()
	test.falsy(hasText("Night Mix"), "the label goes away with the hover")

	screen:close()
	App.player:close()
end)

test.skipIf(not canRender)("opens the playlist dialog from the sidebar tile", function()
	App:init({ scan = false})
	App.settings.root = "/beat-fixtures"
	App.settings.sidebarWidth = 264
	App.settings.sidebarCollapsed = false
	App.library = fixture()
	App.scan = nil
	App.page = { kind = "home"}
	App.taxonomy = core.Taxonomy.new()

	local screen = wonderland.headless.new(function(window, assets)
		App.window = window
		App.assets = assets
		App.covers:use(assets)
		return require("beat.app.pages").view(App, window)
	end, { width = 1200, height = 720})
	screen:draw()

	local message
	for y = 100, 600, 4 do
			local candidate = screen:event({
			name = "mousePress",
			window = screen.window,
			x = 60,
			y = y,
			button = 1,
			})
			if candidate ~= nil and candidate.type == "openPlaylistDialog" and candidate.smart == false then
				message = candidate
				break
			end
		end
	test.truthy(message ~= nil, "the empty playlist tile is a button")
	App:act(message)
	test.truthy(App.playlistDialog ~= nil, "it opens the create-playlist dialog")
	test.equal(App.playlistDialog.smart, false, "the dialog starts on the manual kind")

	screen:close()
	App.player:close()
end)

test.skipIf(not canRender)("aligns track times with the TIME header", function()
	App:init({ scan = false})
	App.settings.root = "/beat-fixtures"
	local library = fixture()
	App.library = library
	App.scan = nil
	App.page = { kind = "album", id = library.albums[1].id}

	local screen = wonderland.headless.new(function(window, assets)
		App.window = window
		App.assets = assets
		App.covers:use(assets)
		return require("beat.app.pages").view(App, window)
	end, { width = 1200, height = 720})
	screen:draw()

	local elements = require("wonderland.element")
	local layout = screen:getPlugin("layout")
	local ctx
	for _, context in pairs(layout.contexts) do ctx = context end
	local tree = ctx.screen
	local headerX, timeX

	local function walk(index, parentX)
		local node = tree:node(index)
		local x = parentX + node.x
		local element = elements.pointers[node.element]
		if element ~= nil and element.text ~= 0 then
			local value = elements.strings[element.text]
			if value == "TIME" then headerX = x
			elseif value == "3:00" and timeX == nil then timeX = x end
		end
		for child = 0, node.childCount - 1 do
				local nextIndex = tree.childIndices[node.firstChild + child - 1]
				if nextIndex ~= nil then walk(nextIndex, x) end
			end
	end
	walk(ctx.root, 0)

	test.truthy(headerX ~= nil, "the table has a TIME header")
	test.truthy(timeX ~= nil, "the first track shows its duration")
	test.equal(timeX, headerX, "durations share the header's left edge")

	screen:close()
	App.player:close()
end)

test.skipIf(not canRender)("windows a long album as it scrolls", function()
	App:init({ scan = false})
	App.settings.root = "/beat-fixtures"
	App.settings.sidebarWidth = 264
	App.settings.sidebarCollapsed = false
	local library = core.Library.new("/beat-fixtures")
	for trackAt = 1, 100 do
			library:add({
			format = "WAV",
			duration = 180,
			tags = { title = string.format("Song %03d", trackAt), artist = "Artist", album = "Long Album",
			albumArtist = "Artist", track = trackAt},
			}, {
			path = "/beat-fixtures/Long/" .. trackAt .. ".wav",
			dir = "/beat-fixtures/Long",
			name = trackAt .. ".wav",
			})
		end
	library:finish()
	App.library = library
	App.scan = nil
	App.page = { kind = "album", id = library.albums[1].id}

	local screen = wonderland.headless.new(function(window, assets)
		App.window = window
		App.assets = assets
		App.covers:use(assets)
		return require("beat.app.pages").view(App, window)
	end, { width = 1200, height = 720})

	local elements = require("wonderland.element")
	local function songTitles()
		local layout = screen:getPlugin("layout")
		local ctx
		for _, value in pairs(layout.contexts) do ctx = value end
		local tree = ctx.screen
		local found = {}
		local function walk(index, parentX, parentY)
			local node = tree:node(index)
			local x, y = parentX + node.x, parentY + node.y
			local element = elements.pointers[node.element]
			if element ~= nil and element.text ~= 0 then
				local value = elements.strings[element.text]
				if value:match("^Song %d+$") and x > 290 then found[#found + 1] = value end
			end
			for child = 0, node.childCount - 1 do
					local nextIndex = tree.childIndices[node.firstChild + child - 1]
					if nextIndex ~= nil then walk(nextIndex, x, y) end
				end
		end
		walk(ctx.root, 0, 0)
		return found
	end

	screen:draw()
	test.equal(songTitles()[1], "Song 001")

	App:act({ type = "scroll", to = 2000})
	screen:draw()
	local after = songTitles()
	test.truthy(#after > 0, "the scrolled track table is not empty")
	test.truthy(after[1] ~= "Song 001", "the visible slice moved")

	screen:close()
	App.player:close()
end)

test.it("adds tracks from a background scan as they arrive", function()
	App:init({ scan = false})
	App.settings.root = "/beat-fixtures"
	App.library = core.Library.new("/beat-fixtures")
	App.page = { kind = "home"}

	local queued = {
	{
	type = "track",
	info = { format = "WAV", duration = 180, tags = { title = "First", artist = "Artist",
	album = "Album", albumArtist = "Artist", track = 1}},
	entry = { path = "/beat-fixtures/1.wav", dir = "/beat-fixtures", name = "1.wav", ext = "wav"},
	coverCache = "/tmp/beat-test-cover.jpg",
	},
	}
	local job = {
	done = false,
	latest = { phase = "inspect", files = 2, inspected = 1, tracks = 1, skipped = 0, errors = {},
	current = "/beat-fixtures/1.wav"},
	}
	function job:poll()
		local events = queued
		queued = {}
		return events, true
	end
	function job:isDone() return self.done end
	function job:hasPending() return #queued > 0 end
	function job:progress() return self.latest end
	function job:close() self.closed = true end
	App.scan = job

	local window = { width = 1200, height = 720, shouldRedraw = false}
	App:tick(10, window)
	test.equal(#App.library.tracks, 1, "the row is usable before the scan finishes")
	test.equal(App.library.tracks[1].title, "First")
	test.equal(App.library.tracks[1].coverCache, "/tmp/beat-test-cover.jpg")
	test.equal(App.library.albums[1].coverCache, "/tmp/beat-test-cover.jpg")
	test.truthy(App.scan ~= nil)

	job.done = true
	job.latest.phase = "done"
	App:tick(11, window)
	test.equal(App.scan, nil)
	test.equal(job.closed, true)
	local summary = App.scanSummary
	test.truthy(summary ~= nil, "the completed scan is summarised")
	if summary ~= nil then
		test.equal(summary.tracks, 1)
		test.equal(summary.albums, 1)
		test.equal(summary.skipped, 0)
	end
	App:act({ type = "dismissScanSummary"})
	test.equal(App.scanSummary, nil, "the summary can be dismissed")

	App.player:close()
end)

test.skipIf(not canRender)("changes theme without rebuilding the whole app", function()
	App:init({ scan = false})
	App.library = fixture()
	App.settings.root = "/beat-fixtures"
	App.page = { kind = "home"}

	local screen = wonderland.headless.new(function(window, assets)
		App.window = window
		App.assets = assets
		App.covers:use(assets)
		return require("beat.app.pages").view(App, window)
	end, { width = 1000, height = 640})

	screen:draw()
	App.settings.theme = "day"
	App:themeChanged()
	screen:draw()
	App.settings.theme = "amoled"
	App.settings.accent = "violet"
	App:themeChanged()
	screen:draw()

	test.equal(App.theme.name, "amoled")
	test.equal(App.theme.accent, "violet")

	App:act({ type = "sidebarWidth", width = 320})
	test.equal(App.settings.sidebarWidth, 320)
	App:act({ type = "sidebarWidth", width = 900})
	test.equal(App.settings.sidebarWidth, 360, "the sidebar width is clamped")

	screen:close()
	App.player:close()
end)

test.it("sorts albums by the newest file they contain", function()
	App:init({ scan = false})
	local library = core.Library.new("/modified-fixtures")
	local function add(album, modified)
		library:add({
		format = "FLAC",
		sampleRate = 44100,
		channels = 2,
		duration = 120,
		tags = { title = album .. " track", artist = "Artist", album = album,
		albumArtist = "Artist", track = 1},
		}, {
		path = "/modified-fixtures/" .. album .. "/1.flac",
		dir = "/modified-fixtures/" .. album,
		name = "1.flac",
		ext = "flac",
		modifyTime = modified,
		}, nil)
	end
	add("Old", 100)
	add("New", 900)
	add("Middle", 500)
	library:finish()
	App.library = library
	App.settings.sort = "modified"

	local albums = App:albumList()
	test.equal(albums[1].title, "New")
	test.equal(albums[2].title, "Middle")
	test.equal(albums[3].title, "Old")
	App.player:close()
end)

test.it("sets the logo as the window icon", function()
	App:init({ scan = false})
	local got
	local window = {
	setIcon = function(_, width, height, rgba)
		got = { width = width, height = height, rgba = rgba}
	end,
	}

	App:setIcon(window)

	test.truthy(got, "the backend was given an icon")
	test.equal(got.width, 256)
	test.equal(got.height, 256)
	test.equal(#got.rgba, 256 * 256 * 4)
	App.player:close()
end)

test.it("stops a page at the scroll limit it was given", function()
	App:init({ scan = false})
	local key = App:pageKey()
	App.scrollMax = 200

	App:act({ type = "scroll", by = 1000})
	test.equal(App.scrollTargets[key], 200, "the wheel cannot carry the page past its bottom")

	App:act({ type = "scroll", to = 999})
	test.equal(App.scroll[key], 200, "and the bar cannot either")
	App.player:close()
end)

test.it("opens and confirms a custom accent colour", function()
	App:init({ scan = false})

	App:act({ type = "openAccentPicker"})
	test.equal(App.accentPickerOpen, true, "the Custom button opens the picker")

	App:act({ type = "pickAccent", value = "#FF7A66"})
	test.equal(App.accentDraft, "#ff7a66", "choosing a swatch only changes the draft")

	App:act({ type = "confirmAccent"})
	test.equal(App.settings.accent, "#ff7a66")
	test.equal(App.theme.accentColour, "#ff7a66")
	test.equal(App.accentPickerOpen, false)
	test.equal(App.accentDraft, nil)
	App.player:close()
end)

test.it("opens an album context menu and dispatches its actions", function()
	App:init({ scan = false})
	App.library = fixture()
	local album = App.library.albums[1]
	local queued

	App:act({ type = "albumMenu", id = album.id, x = 40, y = 50})
	test.truthy(App.contextMenu, "the right click opened a menu")
	test.equal(App.contextMenu.id, album.id)

	local real = App.player
	App.player = {
	playNext = function(_, tracks) queued = #tracks end,
	}
	App:act({ type = "albumMenuNext", id = album.id})
	test.equal(queued, #album.tracks, "Play next receives the album's tracks")
	test.equal(App.contextMenu, nil, "and the menu closes")
	App.player = real

	App.player:close()
end)

test.it("stores equalizer presets and custom band gains", function()
	App:init({ scan = false})
	local applied = {}
	App.player.player = {
	setEqualizer = function(_, bands) applied = bands end,
	}

	App:act({ type = "equalizerPreset", id = "club"})
	test.equal(App.settings.equalizerPreset, "club")
	test.equal(App.settings.equalizerGains[1], 5)
	test.equal(applied[1].gain, 5, "the audio player receives the preset bands")

	App:act({ type = "equalizerGain", band = 2, value = 99})
	test.equal(App.settings.equalizerPreset, "custom")
	test.equal(App.settings.equalizerGains[2], 12, "a band is held to the gain range")
	test.equal(applied[2].gain, 12, "and the change reaches the player immediately")

	App.player.player = nil
end)

test.it("creates, renames and deletes custom equalizer presets", function()
	App:init({ scan = false})
	App.settings.equalizerCustomPresets = {}
	App.settings.equalizerPreset = "flat"
	App.settings.equalizerGains = { 0, 0, 0, 0, 0}
	App.player.player = { setEqualizer = function() end}

	App:act({ type = "equalizerGain", band = 1, value = 6})
	App:act({ type = "newEqualizerPreset"})
	test.equal(App.settings.equalizerPreset, "Custom")
	test.equal(#App.settings.equalizerCustomPresets, 1)
	test.equal(App.settings.equalizerCustomPresets[1].gains[1], 6)

	App:act({ type = "equalizerGain", band = 2, value = 4})
	test.equal(App.settings.equalizerPreset, "Custom", "editing keeps the saved preset selected")
	test.equal(App.settings.equalizerCustomPresets[1].gains[2], 4,
	"editing a saved preset updates the preset itself")

	App:act({ type = "newEqualizerPreset"})
	test.equal(App.settings.equalizerPreset, "Custom 2", "the second preset gets a number")

	App:act({ type = "editEqualizerPreset", name = "Custom 2"})
	App:act({ type = "equalizerEditDraft", value = "Warm"})
	App:act({ type = "saveEqualizerPresetRename"})
	test.equal(App.settings.equalizerPreset, "Warm", "a rename follows the selected preset")
	test.equal(App.settings.equalizerCustomPresets[2].name, "Warm")

	App:act({ type = "deleteEqualizerPreset", name = "Warm"})
	test.equal(#App.settings.equalizerCustomPresets, 1)
	test.equal(App.settings.equalizerPreset, "flat", "deleting the selected preset falls back to Flat")
	test.equal(App.settings.equalizerGains[1], 0)

	App.player.player = nil
end)

test.it("takes at most two initials from a playlist name", function()
	local pages = require("beat.app.pages")
	test.equal(pages.playlistInitials("Maximum Overdrive"), "MO")
	test.equal(pages.playlistInitials("Favourites"), "F")
	test.equal(pages.playlistInitials("  night   drive  "), "ND")
	test.equal(pages.playlistInitials("🎵"), "🎵")
	test.equal(pages.playlistInitials("🎧 DJ Set"), "🎧D")
	test.equal(pages.playlistInitials("🇺🇸"), "🇺🇸")
end)

test.it("uses only a playlist's real tracks in its mosaic", function()
	local pages = require("beat.app.pages")
	local tracks = {}
	for at = 1, 5 do tracks[at] = { id = at} end

	local one = pages.playlistMosaicTracks({ tracks[1]})
	test.equal(#one, 1, "one track is not repeated")
	test.equal(one[1].id, 1)

	local two = pages.playlistMosaicTracks({ tracks[1], tracks[2]})
	test.equal(#two, 2, "two tracks leave the other slots empty")

	local five = pages.playlistMosaicTracks(tracks)
	test.equal(#five, 4)
	test.equal(five[1].id, 1)
	test.equal(five[4].id, 5)
end)
