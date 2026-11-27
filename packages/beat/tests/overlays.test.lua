-- What an open overlay does to the pointer: it covers the window, so the page under it is not
-- hovered, clicked or scrolled through the dim, and a press beside its panel closes it. These
-- draw the shell headless, since it is the shell that puts the layer under an overlay.
local test = require("lde-test")
local wonderland = require("wonderland")
local paths = require("beat.paths")
local Library = require("beat.music.library")
local Taxonomy = require("beat.app.services.collections.taxonomy")
local names = require("beat.music.names")
local App = require("beat.app")
local elements = require("wonderland.element")
local fs = require("fs")

local canRender = true
do
	local ok = pcall(function()
		wonderland.headless.new(function() return wonderland.div() end, { width = 8, height = 8 }):close()
	end)
	canRender = ok
end

local configDirectory = os.tmpname() .. "-beat-overlays"
os.remove(configDirectory)
fs.mkdirAll(configDirectory)

local realDirectory = paths.directory
paths.directory = function() return configDirectory end

test.afterAll(function()
	paths.directory = realDirectory
	fs.rmdir(configDirectory)
end)

local function fixture()
	local library = Library.new("/beat-fixtures")
	for albumAt = 1, 3 do
		local artist = "Artist " .. albumAt
		local dir = "/beat-fixtures/" .. artist .. "/Album " .. albumAt
		for trackAt = 1, 3 do
			library:add(
				{
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
						track = trackAt
					}
				},
				{ path = dir .. "/" .. trackAt .. ".flac", dir = dir, name = trackAt .. ".flac", ext = "flac" },
				nil
			)
		end
	end
	library:finish()
	return library
end

--- An app on its home page with one playlist in the sidebar, and a window drawn over it. Every
--- message the screen makes is handed back to the app and drawn again, the way the loop does.
---@return wonderland.Headless
---@return beat.Library
---@return any
local function openApp()
	App:init({ scan = false })
	App.services.settings.values.root = "/beat-fixtures"
	App.services.settings.values.sidebarWidth = 264
	App.services.settings.values.sidebarCollapsed = false
	local library = fixture()
	App.services.library.current = library
	App.services.scan.job = nil
	App.page = { kind = "home" }
	App.services.collections.taxonomy = Taxonomy.new()
	App.services.collections.save = function() end
	assert(App.services.collections.taxonomy:addPlaylist("Night Mix", false))

	local previousLayout = App.layoutPlugin
	local screen
	screen = wonderland.headless.new(function(window, assets)
		App.window = window
		App.assets = assets
		App.services.covers:use(assets)
		return require("beat.app.shell").view(App, window)
	end, {
		width = 1200,
		height = 720,
		onMessage = function(message)
			App:act(message)
			screen:draw()
		end,
	})
	App.layoutPlugin = assert(screen:getPlugin("layout"))
	screen:draw()

	return screen, library, previousLayout
end

--- Where a box sending a message matching `pick` is on the screen, as the middle of it: the
--- screen's own nodes are the frame that was drawn, so this reads what the pointer would land on.
---@param screen wonderland.Headless
---@param pick fun(message: any): boolean
---@return { x: number, y: number }?
local function centreOf(screen, pick)
	local layout = assert(screen:getPlugin("layout"))
	local ctx
	for _, context in pairs(layout.contexts) do ctx = context end
	local tree = ctx.screen

	local found = nil

	local function walk(index, ox, oy)
		local node = tree:node(index)
		local x, y = ox + node.x, oy + node.y
		local element = elements.pointers[node.element]

		if element ~= nil and element.onclick ~= 0 then
			local message = elements.callbacks[element.onclick]
			if message ~= nil and pick(message) then
				found = { x = x + node.width / 2, y = y + node.height / 2 }
			end
		end

		for child = 0, node.childCount - 1 do
			local nextIndex = tree.childIndices[node.firstChild + child - 1]
			if nextIndex ~= nil then walk(nextIndex, x, y) end
		end
	end

	walk(ctx.root, 0, 0)

	return found
end

---@param message any
---@return boolean
local function playlistRow(message)
	return message.type == "navigate" and message.page ~= nil and message.page.kind == "playlist"
end

test.skipIf(not canRender)("a press beside an open overlay closes it and leaves the page alone", function()
	local screen, library, previousLayout = openApp()

	local row = assert(centreOf(screen, playlistRow), "the sidebar has a playlist row to press")
	App:act({ type = "open", overlay = "playlist_picker", kind = "album", id = library.albums[1].id })
	screen:draw()
	test.truthy(App:overlay("playlist_picker") ~= nil, "the picker is open")

	-- The panel is centred in the window; the sidebar row is beside it, so this is the dim layer.
	screen:click(row.x, row.y)
	test.falsy(App:overlay("playlist_picker"), "the press beside the panel closes the overlay")
	test.equal(App.page.kind, "home", "and it did not reach the row under the dim")

	-- The same press with nothing over it is the row's, which is what says the walk above was a
	-- press the page would have answered.
	screen:click(row.x, row.y)
	test.equal(App.page.kind, "playlist", "the row navigates when no overlay covers it")

	screen:close()
	App.layoutPlugin = previousLayout
	App.services.playback.player:close()
end)

test.skipIf(not canRender)("a press on an open overlay's panel works, and does not close it", function()
	local screen, library, previousLayout = openApp()

	App:act({ type = "open", overlay = "playlist_picker", kind = "album", id = library.albums[1].id })
	screen:draw()
	test.truthy(App:overlay("playlist_picker") ~= nil, "the picker is open")

	-- The left padding of the panel is inside it and outside every row: nothing there sends a
	-- message, so it is the panel's own `keep` that answers, and the overlay stays.
	screen:click(425, 360)
	test.truthy(App:overlay("playlist_picker") ~= nil, "a press in the panel keeps the overlay open")

	screen:close()
	App.layoutPlugin = previousLayout
	App.services.playback.player:close()
end)

test.skipIf(not canRender)("the page under an open overlay is not hovered or wheeled", function()
	local screen, library, previousLayout = openApp()

	local row = assert(centreOf(screen, playlistRow), "the sidebar has a playlist row to point at")

	-- Without an overlay the row answers the pointer, which is the control for what follows.
	screen:event({ name = "mouseMove", window = screen.window, x = row.x, y = row.y })
	test.truthy(App.services.sidebar.hover ~= nil, "the row answers the pointer when nothing covers it")

	App:act({ type = "hoverPlaylist", id = nil })
	App:act({ type = "open", overlay = "playlist_picker", kind = "album", id = library.albums[1].id })
	screen:draw()

	local hovered = screen:event({ name = "mouseMove", window = screen.window, x = row.x, y = row.y })
	test.equal(hovered, nil, "the row under the dim is not told the pointer moved")
	test.equal(App.services.sidebar.hover, nil, "and its tooltip is not opened through the layer")

	-- A wheel over the dim does not reach the page's scroller; over the page with the overlay gone,
	-- the same place asks it to scroll.
	screen:event({ name = "mouseMove", window = screen.window, x = 800, y = 400 })
	local wheel = screen:event({ name = "mouseScroll", window = screen.window, dx = 0, dy = 1 })
	test.equal(wheel, nil, "the wheel over the dim is nobody's")

	App:act({ type = "dismiss" })
	screen:draw()
	local scrolled = screen:event({ name = "mouseScroll", window = screen.window, dx = 0, dy = 1 })
	test.truthy(scrolled ~= nil and scrolled.type == "scroll", "the page scrolls once the overlay is gone")

	App.services.sidebar.hover = nil
	screen:close()
	App.layoutPlugin = previousLayout
	App.services.playback.player:close()
end)

--- The laid out screen the window last built: what the pointer was marked against.
---@param screen wonderland.Headless
local function frameOf(screen)
	local layout = assert(screen:getPlugin("layout"))
	local ctx
	for _, context in pairs(layout.contexts) do ctx = context end
	return ctx
end

--- Every box of that frame, at where it was drawn.
---@param screen wonderland.Headless
---@param visit fun(x: number, y: number, node: wonderland.Node)
local function eachBox(screen, visit)
	local ctx = frameOf(screen)
	local tree = ctx.screen

	local function walk(index, ox, oy)
		local node = tree:node(index)
		local x, y = ox + node.x, oy + node.y
		visit(x, y, node)
		for child = 0, node.childCount - 1 do
			walk(tree.childIndices[node.firstChild + child - 1], x, y)
		end
	end

	walk(ctx.root, 0, 0)
end

--- The message a box's click sends, if it has one.
---@param element wonderland.Element?
---@return any?
local function clickMessage(element)
	if element == nil or element.onclick == 0 then return nil end
	return elements.callbacks[element.onclick]
end

--- The first box whose click message `pick` takes, with where it is: what a pointer at its middle
--- lands on.
---@param screen wonderland.Headless
---@param pick fun(message: any): boolean
---@return { x: number, y: number, width: number, height: number }?
local function rectOf(screen, pick)
	local found
	eachBox(screen, function(x, y, node)
		if found == nil then
			local message = clickMessage(elements.pointers[node.element])
			if type(message) == "table" and pick(message) then
				found = { x = x, y = y, width = node.width, height = node.height }
			end
		end
	end)
	return found
end

--- Whether the frame draws a box hovered whose click message `pick` takes.
---@param screen wonderland.Headless
---@param pick fun(message: any): boolean
---@return boolean
local function isHovered(screen, pick)
	local found = false
	eachBox(screen, function(_, _, node)
		if not found then
			local element = elements.pointers[node.element]
			if element ~= nil and element.flags & elements.HOVERED ~= 0 then
				local message = clickMessage(element)
				if type(message) == "table" and pick(message) then found = true end
			end
		end
	end)
	return found
end

---@param screen wonderland.Headless
---@param x number
---@param y number
local function move(screen, x, y)
	return screen:event({ name = "mouseMove", window = screen.window, x = x, y = y })
end

--- The middle of a box, which is a place nothing else on the screen is unless it is over it.
---@param rect { x: number, y: number, width: number, height: number }
---@return number x
---@return number y
local function middleOf(rect)
	return rect.x + rect.width / 2, rect.y + rect.height / 2
end

--- The frame's tree and the node whose click message `pick` takes, with the boxes above it. A
--- picker row is one box among the panel's ancestors, so a test can read the row's content and
--- the width it was given without knowing either's place in the view.
---@param screen wonderland.Headless
---@param pick fun(message: any): boolean
---@return { tree: any, index: number, x: number, y: number, node: wonderland.Node, ancestors: { x: number, y: number, node: wonderland.Node }[] }?
local function findRow(screen, pick)
	local ctx = frameOf(screen)
	local tree = ctx.screen
	local ancestors = {}
	local found

	local function walk(index, ox, oy)
		local node = tree:node(index)
		local x, y = ox + node.x, oy + node.y
		local element = elements.pointers[node.element]
		local message = element ~= nil and element.onclick ~= 0 and elements.callbacks[element.onclick] or nil
		if found == nil and type(message) == "table" and pick(message) then
			local kept = {}
			for at = 1, #ancestors do kept[at] = ancestors[at] end
			found = { tree = tree, index = index, x = x, y = y, node = node, ancestors = kept }
			return
		end
		ancestors[#ancestors + 1] = { x = x, y = y, node = node }
		for child = 0, node.childCount - 1 do
			local nextIndex = tree.childIndices[node.firstChild + child - 1]
			if nextIndex ~= nil then walk(nextIndex, x, y) end
		end
		ancestors[#ancestors] = nil
	end

	walk(ctx.root, 0, 0)
	return found
end

--- Every box below one found by `findRow`, at where the frame drew it.
---@param row { tree: any, index: number, x: number, y: number }
---@return { x: number, y: number, width: number, height: number }[]
local function boxesBelow(row)
	local boxes = {}
	local function walk(index, ox, oy)
		local node = row.tree:node(index)
		for child = 0, node.childCount - 1 do
			local nextIndex = row.tree.childIndices[node.firstChild + child - 1]
			if nextIndex ~= nil then
				local childNode = row.tree:node(nextIndex)
				local x, y = ox + childNode.x, oy + childNode.y
				boxes[#boxes + 1] = { x = x, y = y, width = childNode.width, height = childNode.height }
				walk(nextIndex, x, y)
			end
		end
	end
	walk(row.index, row.x, row.y)
	return boxes
end

--- The boxes one level below a row found by `findRow`, at where the frame drew them.
---@param row { tree: any, index: number, x: number, y: number }
---@return { x: number, y: number, width: number, height: number }[]
local function boxesIn(row)
	local boxes = {}
	local node = row.tree:node(row.index)
	for child = 0, node.childCount - 1 do
		local nextIndex = row.tree.childIndices[node.firstChild + child - 1]
		if nextIndex ~= nil then
			local childNode = row.tree:node(nextIndex)
			boxes[#boxes + 1] = {
				x = row.x + childNode.x,
				y = row.y + childNode.y,
				width = childNode.width,
				height = childNode.height
			}
		end
	end
	return boxes
end

--- Whether the frame drew a line of this text.
---@param screen wonderland.Headless
---@param want string
---@return boolean
local function hasText(screen, want)
	local found = false
	eachBox(screen, function(_, _, node)
		local element = elements.pointers[node.element]
		if not found and element ~= nil and elements.textOf(element) == want then found = true end
	end)
	return found
end

-- The menu is a panel over a cover: the panel is the pointer's, the cover is not, and nothing the
-- menu is drawn over reaches the pointer until the menu is gone. A click beside the panel is the
-- cover's, which closes the menu and does not also do what the page there does.
test.skipIf(not canRender)("a track menu covers the rows under it", function()
	local screen, library, previousLayout = openApp()
	local album = library.albums[1]
	App.page = { kind = "album", id = album.id }
	screen:draw()

	local trackRow = ---@param id number
		function(id)
			return function(message)
				return type(message) == "table" and message.type == "playTrack" and message.trackId == id
			end
		end
	local first = assert(rectOf(screen, trackRow(album.tracks[1].id)), "the first row is drawn")
	local second = assert(rectOf(screen, trackRow(album.tracks[2].id)), "and so is the second")
	-- A menu on the right of the page, clear of both rows, so the pointer can go to the second
	-- one while it is open: what the menu is drawn over is the window, not the panel.
	App:act({ type = "open", overlay = "menu", menu = "track", id = album.tracks[1].id, x = 700, y = 60 })
	screen:draw()
	test.truthy(App:overlay("menu") ~= nil, "the menu is open")

	local x, y = middleOf(second)
	move(screen, x, y)
	screen:draw()
	test.falsy(isHovered(screen, trackRow(album.tracks[2].id)), "the row under the menu is not hovered")

	screen:click(x, y)
	test.falsy(App:overlay("menu"), "a press beside the panel closes the menu")
	test.equal(App.page.kind, "album", "and it does not reach the row as a navigation")
	test.equal(App.services.playback:current(), nil, "or start playing what was under it")

	-- The same press with the menu gone is the row's, which is what says the place was the row.
	screen:click(x, y)
	local playing = App.services.playback:current()
	test.truthy(playing ~= nil, "the row plays once nothing covers it")
	test.equal(playing and playing.id, album.tracks[2].id, "and it is the track that was under the pointer")

	App.services.playback.player:close()
	screen:close()
	App.layoutPlugin = previousLayout
end)

-- The shuffle button's menu is opened from the button itself, so the button is the first thing
-- under the cover: hovering it while the menu is open must not light it up and a press on it must
-- close the menu rather than shuffle.
test.skipIf(not canRender)("the shuffle menu covers the shuffle button", function()
	local screen, library, previousLayout = openApp()
	App.services.playback.player:playTracks(library.albums[1].tracks, 1)
	screen:draw()

	local shuffle = assert(rectOf(screen, function(message) return message.type == "shuffle" end), "the bar has a shuffle button")
	local x, y = middleOf(shuffle)
	move(screen, x, y)
	screen:draw()
	test.truthy(isHovered(screen, function(message) return message.type == "shuffle" end),
		"the button answers the pointer when nothing covers it")

	App:act({ type = "open", overlay = "menu", menu = "shuffle", x = 20, y = 20 })
	screen:draw()
	test.truthy(App:overlay("menu") ~= nil, "the menu is open")
	test.equal(App.services.playback.player.queue.shuffleMode, "off", "with shuffle off")

	move(screen, x, y)
	screen:draw()
	test.falsy(isHovered(screen, function(message) return message.type == "shuffle" end),
		"the button under the menu is not hovered")

	screen:click(x, y)
	test.falsy(App:overlay("menu"), "a press on the button under the menu closes the menu")
	test.equal(App.services.playback.player.queue.shuffleMode, "off", "and does not shorten the queue")

	-- The same press with the menu gone is the button's.
	screen:click(x, y)
	test.equal(App.services.playback.player.queue.shuffleMode, "tracks", "the button shuffles once it is clear")

	App.services.playback.player:close()
	screen:close()
	App.layoutPlugin = previousLayout
end)

-- The same, over the screen that draws the button: now playing is full-screen, so its menu is the
-- only layer over it and the button is still the menu's to cover.
test.skipIf(not canRender)("the shuffle menu over now playing covers its shuffle button", function()
	local screen, library, previousLayout = openApp()
	App.services.playback.player:playTracks(library.albums[1].tracks, 1)
	App.page = { kind = "album", id = library.albums[1].id }
	App:open("now_playing")
	screen:draw()

	local shuffle = assert(rectOf(screen, function(message) return message.type == "shuffle" end),
		"now playing has a shuffle button")
	local x, y = middleOf(shuffle)
	App:act({ type = "open", overlay = "menu", menu = "shuffle", x = 20, y = 20 })
	screen:draw()

	move(screen, x, y)
	screen:draw()
	test.falsy(isHovered(screen, function(message) return message.type == "shuffle" end),
		"the button under the menu is not hovered")

	screen:click(x, y)
	test.falsy(App:overlay("menu"), "the press closes the menu")
	test.equal(App.services.playback.player.queue.shuffleMode, "off", "and does not shuffle")

	App.services.playback.player:close()
	screen:close()
	App.layoutPlugin = previousLayout
end)

-- The panels popped out of now playing's tool row are drawn inside that screen and the cover
-- under them is the shell's, so what the panel holds is above it: the volume slider is the
-- pointer's while the controls around it are not, and the queue's rows play.
test.skipIf(not canRender)("a tool panel is the pointer's and covers the controls under it", function()
	local screen, library, previousLayout = openApp()
	App.services.playback.player:playTracks(library.albums[1].tracks, 1)
	App.page = { kind = "album", id = library.albums[1].id }
	App:open("now_playing")
	screen:draw()

	-- Volume: the panel is a row with a mute button and a slider, and it is over the cover.
	App:act({ type = "open", overlay = "volume" })
	screen:draw()
	local panel = assert(rectOf(screen, function(message) return message.type == "keep" end), "the volume panel is drawn")
	local volumeBefore = App.services.settings.values.volume
	local sliderX, sliderY = panel.x + panel.width - 40, panel.y + panel.height / 2
	move(screen, sliderX, sliderY)
	screen:draw()
	test.truthy(isHovered(screen, function(message) return message.type == "keep" end),
		"the panel under the pointer is hovered")

	screen:click(sliderX, sliderY)
	test.truthy(App:overlay("volume") ~= nil, "a press on the slider keeps the panel open")
	test.truthy(App.services.settings.values.volume ~= volumeBefore, "and sets the volume")

	local shuffle = assert(rectOf(screen, function(message) return message.type == "shuffle" end), "the shuffle button is drawn")
	local x, y = middleOf(shuffle)
	move(screen, x, y)
	screen:draw()
	test.falsy(isHovered(screen, function(message) return message.type == "shuffle" end),
		"the controls under the panel are not hovered")
	screen:click(x, y)
	test.falsy(App:overlay("volume"), "a press on them closes the panel")
	test.equal(App.services.playback.player.queue.shuffleMode, "off", "and does not shuffle")

	-- The queue: its rows are above the cover too. It lists what comes after the current track,
	-- so its second row starts the third track.
	App:act({ type = "open", overlay = "queue" })
	App.services.motion.clock:set("queuePanel", 1)
	screen:draw()
	local queue = assert(rectOf(screen, function(message) return message.type == "keep" end), "the queue panel is drawn")
	-- The panel pads itself, then a header, a gap, and 48 px rows: the second row is one of them in.
	local rowX, rowY = queue.x + queue.width / 2, queue.y + 10 + 24 + 4 + 48 + 24
	screen:click(rowX, rowY)
	local playing = App.services.playback:current()
	test.truthy(playing ~= nil and playing.title == library.albums[1].tracks[3].title,
		"a queue row under the pointer is the row that plays")

	-- The more panel is the third of them, with the same popup: its rows are the pointer's too.
	App:act({ type = "open", overlay = "more" })
	App.services.motion.clock:set("moreMenu", 1)
	screen:draw()
	---@param message any
	---@return boolean
	local function tagRow(message)
		return type(message) == "table" and message.overlay == "tag_picker"
	end
	local moreRow = assert(rectOf(screen, tagRow), "the more panel draws its rows")
	local moreX, moreY = middleOf(moreRow)
	move(screen, moreX, moreY)
	screen:draw()
	test.truthy(isHovered(screen, tagRow), "a row of the more panel is hovered over the cover")

	App.services.playback.player:close()
	screen:close()
	App.layoutPlugin = previousLayout
end)

-- A menu draws its rows as boxes with their own hover styles, and the frame has to say which one
-- the pointer is on after every move, whether or not a frame was built in between: a move that
-- enters a row asks for a frame, a move within the row it is already on asks for none.
test.skipIf(not canRender)("the hovered menu row follows the pointer", function()
	local screen, library, previousLayout = openApp()
	App.services.playback.player:playTracks(library.albums[1].tracks, 1)
	screen:draw()
	App:act({ type = "open", overlay = "menu", menu = "shuffle", x = 20, y = 20 })
	screen:draw()

	---@param mode string
	---@return fun(message: any): boolean
	local function row(mode)
		return function(message)
			return type(message) == "table" and message.type == "shuffleMode" and message.mode == mode
		end
	end

	---@return string?
	local function hoveredMode()
		local mode = nil
		eachBox(screen, function(_, _, node)
			local element = elements.pointers[node.element]
			if element ~= nil and element.flags & elements.HOVERED ~= 0 and mode == nil then
				local message = clickMessage(element)
				if type(message) == "table" and message.type == "shuffleMode" then mode = message.mode end
			end
		end)
		return mode
	end

	-- The first three rows of the menu, in the order it draws them.
	local rects = {}
	for _, mode in ipairs({ "tracks", "albums", "artists" }) do
		rects[mode] = assert(rectOf(screen, row(mode)), "the menu draws its " .. mode .. " row")
	end

	-- A move at a time, with the frame it asks for after each: the row under the pointer is the
	-- one the frame draws hovered.
	for _, mode in ipairs({ "tracks", "albums", "artists" }) do
		local x, y = middleOf(rects[mode])
		move(screen, x, y)
		screen:draw()
		test.equal(hoveredMode(), mode, "the pointer is on the " .. mode .. " row")
	end

	-- Moves in one go, with the frame after all of them: what is drawn is where the pointer ended.
	for _, mode in ipairs({ "tracks", "albums", "artists" }) do
		local x, y = middleOf(rects[mode])
		move(screen, x, y)
	end
	screen:draw()
	test.equal(hoveredMode(), "artists", "the row the pointer came to is the one drawn hovered")

	-- A move within the row it is on changes nothing, so it asks for no frame at all; leaving the
	-- row for the next one does.
	local x, y = middleOf(rects.artists)
	move(screen, x, y)
	screen:draw()
	move(screen, x + 1, y + 1)
	test.falsy(frameOf(screen).hoverChanged, "a move within the hovered row asks for no frame")
	local nextX, nextY = middleOf(rects.tracks)
	move(screen, nextX, nextY)
	test.truthy(frameOf(screen).hoverChanged, "and a move to another row does")
	screen:draw()
	test.equal(hoveredMode(), "tracks", "and that row is the one drawn hovered")

	App.services.playback.player:close()
	screen:close()
	App.layoutPlugin = previousLayout
end)

-- The picker's rows are the panel's own width, not the width of their words: a row's fill is what
-- shows the pointer where the press will land, so it has to cover the whole line, and the create
-- row's '+' has to be inside it rather than beside it.
test.skipIf(not canRender)("picker rows fill the panel and centre their content", function()
	local screen, library, previousLayout = openApp()
	App:act({ type = "open", overlay = "playlist_picker", kind = "album", id = library.albums[1].id })
	screen:draw()

	local create = assert(findRow(screen, function(message) return message.type == "newPlaylistWithItem" end), "the create row is drawn")
	local row = assert(findRow(screen, function(message) return message.type == "addToPlaylist" end), "a playlist row is drawn")
	test.equal(create.x, row.x, "the create row starts where a playlist row does")
	test.equal(create.node.width, row.node.width, "and is the same width")

	-- The panel is the row's nearest ancestor that keeps a press; the row is inset from it by the
	-- panel's own padding on both sides, so its fill is the panel's inner width.
	local panel
	for at = #row.ancestors, 1, -1 do
		local box = row.ancestors[at]
		local element = elements.pointers[box.node.element]
		local message = element ~= nil and element.onclick ~= 0 and elements.callbacks[element.onclick] or nil
		if type(message) == "table" and message.type == "keep" then
			panel = box
			break
		end
	end
	panel = assert(panel, "the row is inside the picker's panel")
	local inset = row.x - panel.x
	-- The panel pads both sides and its drawn border sits outside the content, so the row is the
	-- frame's width less two paddings and two border widths.
	local border = (panel.node.borderLeft or 0) + (panel.node.borderRight or 0)
	test.equal(panel.node.width - row.node.width, inset * 2 + border, "the row spans the panel's inner width")

	-- The pointer lights the row's whole fill, not only the line of text on it.
	local x, y = middleOf({ x = row.x, y = row.y, width = row.node.width, height = row.node.height })
	move(screen, x, y)
	screen:draw()
	local hovered
	eachBox(screen, function(bx, by, node)
		if hovered == nil then
			local element = elements.pointers[node.element]
			if element ~= nil and element.flags & elements.HOVERED ~= 0 then
				local message = clickMessage(element)
				if type(message) == "table" and message.type == "addToPlaylist" then
					hovered = { x = bx, y = by, width = node.width, height = node.height }
				end
			end
		end
	end)
	hovered = assert(hovered, "the row under the pointer is drawn hovered")
	test.equal(hovered.x, row.x, "the hover fill starts at the row's left edge")
	test.equal(hovered.width, row.node.width, "and is as wide as the row")

	-- Every box a row draws is inside the row and on its one line; the create row's badge, the
	-- '+' itself, is one of them.
	for _, found in ipairs({ create, row }) do
		local centre = found.y + found.node.height / 2
		for _, box in ipairs(boxesBelow(found)) do
			test.truthy(
				box.x >= found.x and box.x + box.width <= found.x + found.node.width + 1,
				"row content stays inside the row's fill"
			)
		end
		for _, box in ipairs(boxesIn(found)) do
			test.truthy(math.abs(box.y + box.height / 2 - centre) <= 1, "labels and counts share the row's centre line")
		end
	end
	test.truthy(#boxesIn(create) >= 2, "the create row draws its badge and its name")
	test.truthy(#boxesBelow(create) > #boxesIn(create), "the '+' is inside the badge")

	App.services.playback.player:close()
	screen:close()
	App.layoutPlugin = previousLayout
end)

-- Both kinds of item reach the same picker, and the panel says which one it will file away.
test.skipIf(not canRender)("the album and track menus both open the picker", function()
	local screen, library, previousLayout = openApp()
	local album = library.albums[1]
	App.page = { kind = "album", id = album.id }
	screen:draw()

	App:act({ type = "open", overlay = "menu", menu = "album", id = album.id, x = 700, y = 60 })
	screen:draw()
	local albumAdd = assert(
		rectOf(screen, function(message)
			return message.type == "open" and message.overlay == "playlist_picker" and message.kind == "album"
		end),
		"the album menu offers a playlist"
	)
	local x, y = middleOf(albumAdd)
	screen:click(x, y)
	screen:draw()
	local picker = assert(App:overlay("playlist_picker"), "the album menu opens the picker")
	test.equal(picker.state.kind, "album")
	test.truthy(hasText(screen, "Add album to playlist"), "the picker names the album")

	App:act({ type = "dismiss" })
	screen:draw()

	App:act({ type = "open", overlay = "menu", menu = "track", id = album.tracks[1].id, x = 700, y = 60 })
	screen:draw()
	local trackAdd = assert(
		rectOf(screen, function(message)
			return message.type == "open" and message.overlay == "playlist_picker" and message.kind == "track"
		end),
		"the track menu offers a playlist"
	)
	x, y = middleOf(trackAdd)
	screen:click(x, y)
	screen:draw()
	picker = assert(App:overlay("playlist_picker"), "the track menu opens the picker")
	test.equal(picker.state.kind, "track")
	test.truthy(hasText(screen, "Add track to playlist"), "the picker names the track")

	App.services.playback.player:close()
	screen:close()
	App.layoutPlugin = previousLayout
end)

-- A track row on a manual playlist page can be taken out of it where the listener pointed, the
-- write lands in tags.json at once, and the undo puts the same track back on the same row.
test.skipIf(not canRender)("a playlist row's menu removes that row and persists it", function()
	local screen, library, previousLayout = openApp()
	local Collections = require("beat.app.services.collections")
	local TagStore = require("beat.app.services.collections.store")
	local playlist = assert(App.services.collections.taxonomy:addPlaylist("Mix", false))
	local album = library.albums[1]
	App.services.collections.taxonomy:setPlaylistAlbum(playlist, album)
	-- openApp silences the write for its other cases; this one watches it land.
	App.services.collections.save = Collections.save
	App.page = { kind = "playlist", id = playlist.id }
	screen:draw()

	local target = album.tracks[2]
	App:act({ type = "open", overlay = "menu", menu = "track", id = target.id, x = 700, y = 60 })
	screen:draw()
	test.truthy(App:overlay("menu") ~= nil, "the row menu is open")
	local remove = assert(
		rectOf(screen, function(message)
			return message.type == "playlistRemove" and message.playlist == playlist.id and message.index == 2
		end),
		"the menu names the playlist and the row that was clicked"
	)

	local x, y = middleOf(remove)
	screen:click(x, y)
	test.falsy(App:overlay("menu"), "removing closes the menu")
	test.equal(App.services.toasts.list[#App.services.toasts.list].text, "Removed from Mix")

	local remaining = App.services.collections.taxonomy:playlistTracks(playlist, library)
	test.equal(#remaining, 2)
	test.equal(remaining[1].id, album.tracks[1].id)
	test.equal(remaining[2].id, album.tracks[3].id)

	local loaded = TagStore.load()
	local saved = assert(loaded:playlist(playlist.id), "the playlist is on disk")
	local savedTracks = loaded:playlistTracks(saved, library)
	test.equal(#savedTracks, 2)
	for _, track in ipairs(savedTracks) do
		test.truthy(track.id ~= target.id, "the removed occurrence is not in the written playlist")
	end

	App:act({ type = "playlistRestore", playlist = playlist.id, id = target.id, index = 2 })
	local restored = App.services.collections.taxonomy:playlistTracks(playlist, library)
	test.equal(#restored, 3)
	test.equal(restored[2].id, target.id, "undo puts the track back on the row it left")

	App.services.playback.player:close()
	screen:close()
	App.layoutPlugin = previousLayout
end)

-- A smart list's tracks come from its tag rules, so there is no hand-added row for a menu to
-- take out, and the menu the page opens has no removal entry.
test.skipIf(not canRender)("a smart playlist's track menu has no removal", function()
	local screen, library, previousLayout = openApp()
	local taxonomy = App.services.collections.taxonomy
	local tag = assert(taxonomy:addTag("Focus"))
	local auto
	for _, playlist in ipairs(taxonomy.playlists) do
		if playlist.autoTagId == tag.id then auto = playlist end
	end
	auto = assert(auto, "the tag's automatic playlist exists")
	taxonomy:setTag(names.trackKey(library.albums[1].tracks[1]), tag.id, true)
	App.page = { kind = "playlist", id = auto.id }
	screen:draw()

	App:act({ type = "open", overlay = "menu", menu = "track", id = library.albums[1].tracks[1].id, x = 700, y = 60 })
	screen:draw()
	test.truthy(App:overlay("menu") ~= nil, "the track menu opens on a smart playlist")
	test.falsy(
		rectOf(screen, function(message) return message.type == "playlistRemove" end),
		"a smart playlist's rules offer nothing to remove"
	)

	App.services.playback.player:close()
	screen:close()
	App.layoutPlugin = previousLayout
end)
