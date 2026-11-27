-- The queue panel's editing gestures: the remove button a pointer reveals, a row dragged to another
-- place, and a phone's swipe and hold. The panel is drawn on its own here, at a place the test can
-- work out from the theme, so a press lands on the row it names rather than on a screen's furniture.
local test = require("lde-test")
local fs = require("fs")
local wonderland = require("wonderland")
local paths = require("beat.paths")
local App = require("beat.app")
local Queue = require("beat.app.services.playback.queue")

local div, sty = wonderland.div, wonderland.sty

local configDirectory = os.tmpname() .. "-beat-queue-ui"
os.remove(configDirectory)
fs.mkdirAll(configDirectory)

local realDirectory = paths.directory
paths.directory = function() return configDirectory end

test.afterEach(function()
	if App.services ~= nil and App.services.playback ~= nil then App.services.playback.player:close() end
	App.layoutPlugin = nil
	fs.delete(paths.file("settings.json"))
end)

test.afterAll(function()
	paths.directory = realDirectory
	fs.rmdir(configDirectory)
end)

local canRender = true
do
	local ok = pcall(function()
		wonderland.headless.new(function() return wonderland.div() end, { width = 8, height = 8 }):close()
	end)
	canRender = ok
end

--- The rows the panel will show, as the player's queue holds them.
---@param count number
local function tracks(count)
	local list = {}
	for at = 1, count do
		list[at] = { id = at, title = "Track " .. at, artist = "Artist", duration = 180 + at }
	end
	return list
end

--- Opens the panel over a queue of `count` tracks and gives it a place on an otherwise empty
--- screen: the tool row at `top`, the panel under it, and the rows at the sizes the view will use.
---@param count number
---@param top number?
---@param roomHeight number?
local function openQueue(count, top, roomHeight)
	App.services.playback.player.queue = Queue.new(tracks(count), 1)
	App:open("queue")
	local overlay = assert(App:overlay("queue"))
	local theme = App.services.appearance.theme
	overlay.state.anchor = {
		toolWidth = theme:px(340),
		room = {
			below = roomHeight or theme:px(700),
			above = roomHeight or theme:px(700),
			top = top or theme:px(100),
			rowHeight = theme:px(48)
		}
	}
	-- The reveal is an animation; the test presses at the panel's finished place.
	App.services.motion.clock:set("queuePanel", 1)
	return overlay, theme
end

--- Where the panel's list is, worked out the way the view works it out.
---@param theme beat.Theme
---@param top number?
---@param roomHeight number?
---@param count number?
---@return { rowY: fun(index: number): number, rowX: number, removeX: number, rowHeight: number, listWidth: number, listTop: number, listHeight: number }
local function geometry(theme, top, roomHeight, count)
	local padding = theme:px(10)
	local headerHeight = theme:px(24)
	local gap = theme:px(4)
	local rowHeight = theme:px(48)
	local width = theme:px(340)
	-- The panel pops out under the tool row it is anchored to.
	local panelY = (top or theme:px(100)) + theme:px(48) + theme:px(6)
	local listTop = panelY + padding + headerHeight + gap
	local listInner = width - padding * 2
	local rowX = padding
	local removeX = rowX + listInner - theme:px(8) - theme:px(32) / 2
	local space = math.max(roomHeight or theme:px(700), roomHeight or theme:px(700)) - theme:px(6)
	local fixed = padding * 2 + headerHeight + gap
	local listHeight = math.max(rowHeight, math.min((count or 7) * rowHeight, space - fixed))
	return {
		rowHeight = rowHeight,
		listWidth = listInner,
		rowX = rowX,
		removeX = removeX,
		listTop = listTop,
		listHeight = listHeight,
		rowY = function(index) return listTop + (index - 1) * rowHeight + rowHeight / 2 end
	}
end

--- A screen that draws only the open queue panel, so its rows are where `geometry` says.
---@param width number
---@param height number
---@param messages table # Every message the panel sends, in order
---@param act boolean? # Whether the app takes the messages; a test of what is sent only records them
local function queueScreen(width, height, messages, act)
	local rendered
	rendered = wonderland.headless.new(function(window, assets)
		App.window = window
		App.assets = assets
		App.services.covers:use(assets)
		local surface = App.registry:overlay("queue")
		local overlay = App:overlay("queue")
		if overlay == nil then return div():style(sty():w(width):h(height)) end
		return assert(surface.view(App, overlay, window))
	end, {
		width = width,
		height = height,
		onMessage = function(message)
			messages[#messages + 1] = message
			if act ~= false then App:act(message) end
			rendered:draw()
		end
	})
	App.layoutPlugin = assert(rendered:getPlugin("layout"))
	return rendered
end

--- Whether the frame has an element with this text in it.
---@param screen wonderland.Headless
---@param value string
---@return boolean
local function hasText(screen, value)
	local layout = screen:getPlugin("layout")
	local ctx
	for _, context in pairs(layout.contexts) do ctx = context end
	if ctx == nil then return false end

	local elements = require("wonderland.element")
	local found = false
	local function walk(index)
		if found then return end
		local node = ctx.screen:node(index)
		local element = elements.pointers[node.element]
		if element ~= nil and elements.textOf(element) == value then
			found = true
			return
		end
		for child = 0, node.childCount - 1 do
			local nextIndex = ctx.screen.childIndices[node.firstChild + child - 1]
			if nextIndex ~= nil then walk(nextIndex) end
		end
	end
	walk(ctx.root)
	return found
end

---@param messages table
---@param kind string
---@return table?
local function lastOf(messages, kind)
	for at = #messages, 1, -1 do
		if messages[at].type == kind then return messages[at] end
	end
	return nil
end

---@param messages table
---@param kind string
---@return number
local function countOf(messages, kind)
	local count = 0
	for _, message in ipairs(messages) do
		if message.type == kind then count = count + 1 end
	end
	return count
end

test.skipIf(not canRender)("reveals a remove button on hover and sends the row's place", function()
	App:init({ scan = false })
	local _, theme = openQueue(6)
	local where = geometry(theme)
	local messages = {}
	local screen = queueScreen(1200, 760, messages)
	screen:draw()

	test.falsy(hasText(screen, "×"), "no row shows its button until a pointer is over it")
	test.truthy(hasText(screen, "Track 2"), "the panel draws the queue")

	-- A move, not a click: hover is what puts the button on the row.
	screen:event({
		name = "mouseMove",
		window = screen.window,
		x = where.removeX,
		y = where.rowY(2)
	})
	screen:draw()
	test.truthy(hasText(screen, "×"), "the hovered row has its remove button")
	test.truthy(App:overlay("queue") ~= nil, "hovering does not close the panel")

	screen:click(where.removeX, where.rowY(2))
	test.equal(countOf(messages, "queueRemove"), 1, "the button sent one remove")
	test.equal(lastOf(messages, "queueRemove").index, 2, "and it named the second row")
	test.truthy(App:overlay("queue") ~= nil, "taking a row out leaves the panel open")

	screen:close()
end)

test.skipIf(not canRender)("still plays a row that is only tapped", function()
	App:init({ scan = false })
	local _, theme = openQueue(6)
	local where = geometry(theme)
	local messages = {}
	local screen = queueScreen(1200, 760, messages, false)
	screen:draw()

	screen:click(where.rowX + 80, where.rowY(1))
	local jump = lastOf(messages, "jumpTrack")
	test.truthy(jump ~= nil, "a tap plays the row")
	test.equal(jump.trackId, 2, "the first upcoming track")

	screen:close()
end)

test.skipIf(not canRender)("drags a row down past two others and sends where it landed", function()
	App:init({ scan = false })
	local _, theme = openQueue(6)
	local where = geometry(theme)
	local messages = {}
	local screen = queueScreen(1200, 760, messages)
	screen:draw()

	-- Row 2's middle taken to the middle of row 4's lower half: two rows of travel, and its
	-- place after the drag is 4.
	local fromY = where.rowY(2)
	screen:drag(where.rowX + 80, fromY, where.rowX + 80, fromY + where.rowHeight * 2.5)

	local moved = lastOf(messages, "queueMove")
	test.truthy(moved ~= nil, "the drag sent a move")
	test.equal(moved.from, 2, "from the second row")
	test.equal(moved.to, 4, "to the fourth place")
	test.truthy(App:overlay("queue") ~= nil, "reordering leaves the panel open")

	screen:close()
end)

test.skipIf(not canRender)("removes a row swiped past forty percent and keeps a short one", function()
	App:init({ scan = false })
	local _, theme = openQueue(6)
	local where = geometry(theme)
	local messages = {}
	local screen = queueScreen(520, 760, messages)
	screen:draw()

	local y = where.rowY(1)
	local startX = where.rowX + 40
	screen:drag(startX, y, startX + where.listWidth * 0.6, y)
	test.equal(countOf(messages, "queueRemove"), 1, "a swipe past the threshold removes the row")
	test.equal(lastOf(messages, "queueRemove").index, 1, "the row that was swiped")
	screen:close()

	-- A shorter slide is let go of and snaps back: no remove, and no jump out of the panel either.
	App:close("queue")
	openQueue(6)
	messages = {}
	local again = queueScreen(520, 760, messages)
	again:draw()
	again:drag(startX, y, startX + where.listWidth * 0.2, y)
	test.equal(countOf(messages, "queueRemove"), 0, "a short swipe sends nothing out of the queue")
	test.truthy(App:overlay("queue") ~= nil, "and the panel is still open")
	again:close()
end)

test.skipIf(not canRender)("scrolls the list when a dragged row reaches an edge", function()
	App:init({ scan = false })
	local room = App.services.appearance.theme:px(220)
	local overlay, theme = openQueue(30, nil, room)
	local where = geometry(theme, nil, room, 30)
	local messages = {}
	local screen = queueScreen(1200, 760, messages)
	screen:draw()

	local x, y = where.rowX + 80, where.rowY(2)
	screen:event({ name = "mouseMove", window = screen.window, x = x, y = y })
	screen:event({ name = "mousePress", window = screen.window, x = x, y = y, button = 1 })
	local edgeY = where.listTop + where.listHeight - theme:px(2)
	screen:event({ name = "mouseMove", window = screen.window, x = x, y = edgeY })

	local scroll = lastOf(messages, "scroll")
	test.truthy(scroll ~= nil, "the edge sent the list a scroll")
	test.equal(scroll.key, "queue", "for the queue")
	test.truthy(App.services.scroll:offset("queue") > 0, "and the list moved")
	test.equal(countOf(messages, "queueMove"), 0, "the row is still being held")

	screen:event({ name = "mouseRelease", window = screen.window, x = x, y = edgeY, button = 1 })
	screen:close()
end)

test.skipIf(not canRender)("holds a row, feels it, and drags it on a phone", function()
	App:init({ scan = false })
	local overlay, theme = openQueue(6)
	local where = geometry(theme)
	local messages = {}
	local screen = queueScreen(520, 760, messages)
	screen:draw()

	local felt = 0
	local realHaptics = App.services.haptics
	App.services.haptics = { tick = function() felt = felt + 1 end }

	local x, y = where.rowX + 80, where.rowY(1)
	screen:event({ name = "mouseMove", window = screen.window, x = x, y = y })
	screen:event({ name = "mousePress", window = screen.window, x = x, y = y, button = 1 })
	-- The finger has been down longer than a hold. The move after it is the drag's first.
	overlay.state.press.at = require("wonderland").time.now() - 1
	screen:event({ name = "mouseMove", window = screen.window, x = x, y = y + where.rowHeight * 0.2 })
	test.equal(felt, 1, "the hold is felt once the row can be dragged")

	screen:event({ name = "mouseMove", window = screen.window, x = x, y = y + where.rowHeight * 2 })
	screen:event({ name = "mouseRelease", window = screen.window, x = x, y = y + where.rowHeight * 2, button = 1 })
	App.services.haptics = realHaptics

	local moved = lastOf(messages, "queueMove")
	test.truthy(moved ~= nil, "the held row was dragged")
	test.equal(moved.from, 1, "from the first row")
	test.equal(moved.to, 3, "to the third place")
	test.truthy(App:overlay("queue") ~= nil, "the panel stayed open")

	screen:close()
end)

test.skipIf(not canRender)("takes a phone's touch: the hold drags, a swipe removes, a move before the hold scrolls", function()
	App:init({ scan = false })
	local room = App.services.appearance.theme:px(220)
	local overlay, theme = openQueue(30, nil, room)
	local where = geometry(theme, nil, room, 30)
	local messages = {}
	local screen = queueScreen(520, 760, messages)
	screen:draw()

	-- What the Android backend hands over once the layout claimed the touch: the press goes down
	-- with the finger, and the moves after the hold are the row's own rather than a scroll.
	local claims = {}
	screen.window.captureTouch = function(_, hold)
		claims[#claims + 1] = hold
		return true
	end

	local x, y = where.rowX + 80, where.rowY(1)
	screen:event({ name = "touchStart", window = screen.window, id = 1, x = x, y = y, pressure = 1 })
	test.equal(#claims, 1, "the queue's list takes the touch")
	test.equal(claims[1], 0.35, "with the hold its own gesture times itself against")

	screen:event({ name = "mouseMove", window = screen.window, x = x, y = y })
	screen:event({ name = "mousePress", window = screen.window, x = x, y = y, button = 1 })
	-- The finger rested past the hold, so the move that follows is the drag's first.
	overlay.state.press.at = require("wonderland").time.now() - 1
	local toY = y + where.rowHeight * 2
	screen:event({ name = "mouseMove", window = screen.window, x = x, y = toY })
	screen:event({ name = "mouseMove", window = screen.window, x = x, y = toY })
	screen:event({ name = "mouseRelease", window = screen.window, x = x, y = toY, button = 1 })
	screen:event({ name = "mouseLeave", window = screen.window })

	local moved = lastOf(messages, "queueMove")
	test.truthy(moved ~= nil, "the held row was dragged")
	test.equal(moved.from, 1, "from the first row")
	test.equal(moved.to, 3, "to the third place")

	-- A hold let go of without moving is the row being offered for a drag, not played.
	local holdY = where.rowY(2)
	screen:event({ name = "mouseMove", window = screen.window, x = x, y = holdY })
	screen:event({ name = "mousePress", window = screen.window, x = x, y = holdY, button = 1 })
	overlay.state.press.at = require("wonderland").time.now() - 1
	screen:event({ name = "mouseRelease", window = screen.window, x = x, y = holdY, button = 1 })
	test.equal(countOf(messages, "jumpTrack"), 0, "a hold let go of without moving plays nothing")
	screen:close()

	-- Sideways across a row is a swipe, which takes it out.
	App:close("queue")
	openQueue(6)
	messages = {}
	local swipeWhere = geometry(theme)
	local swiped = queueScreen(520, 760, messages)
	swiped:draw()
	swiped.window.captureTouch = function() return true end
	local sx, sy = swipeWhere.rowX + 40, swipeWhere.rowY(2)
	swiped:event({ name = "touchStart", window = swiped.window, id = 1, x = sx, y = sy, pressure = 1 })
	swiped:event({ name = "mouseMove", window = swiped.window, x = sx, y = sy })
	swiped:event({ name = "mousePress", window = swiped.window, x = sx, y = sy, button = 1 })
	swiped:event({ name = "mouseMove", window = swiped.window, x = sx + swipeWhere.listWidth * 0.6, y = sy })
	swiped:event({
		name = "mouseRelease", window = swiped.window,
		x = sx + swipeWhere.listWidth * 0.6, y = sy, button = 1,
	})
	swiped:event({ name = "mouseLeave", window = swiped.window })
	test.equal(countOf(messages, "queueRemove"), 1, "the swipe took a row out")
	test.equal(lastOf(messages, "queueRemove").index, 2, "the row that was swiped")
	swiped:close()

	-- Up or down before the hold is the list scrolling, and nothing about a row: the backend lets
	-- the claimed press go and sends the scroll it would have sent for any touch.
	App:close("queue")
	openQueue(30, nil, room)
	messages = {}
	local scrolled = queueScreen(520, 760, messages)
	scrolled:draw()
	scrolled.window.captureTouch = function() return true end
	local cx, cy = where.rowX + 80, where.rowY(1)
	scrolled:event({ name = "touchStart", window = scrolled.window, id = 1, x = cx, y = cy, pressure = 1 })
	scrolled:event({ name = "mouseMove", window = scrolled.window, x = cx, y = cy })
	scrolled:event({ name = "mousePress", window = scrolled.window, x = cx, y = cy, button = 1 })
	scrolled:event({ name = "mouseRelease", window = scrolled.window, x = cx, y = cy - where.rowHeight, button = 1 })
	scrolled:event({
		name = "mouseScroll", window = scrolled.window,
		x = cx, y = cy, dx = 0, dy = where.rowHeight, pixels = true,
	})
	scrolled:event({ name = "mouseLeave", window = scrolled.window })

	test.truthy(countOf(messages, "scroll") >= 1, "the list scrolled")
	test.truthy(App.services.scroll:offset("queue") > 0, "and it moved")
	test.equal(countOf(messages, "queueMove"), 0, "no row was moved")
	test.equal(countOf(messages, "queueRemove"), 0, "none was taken out")
	test.equal(countOf(messages, "jumpTrack"), 0, "and none was played")
	scrolled:close()
end)
