-- The rail's width between its two forms: the toggle and the window's breakpoint ease it, the
-- grip's own drag does not, and the motion service is what keeps frames coming until it settles.
local test = require("lde-test")
local Sidebar = require("beat.app.services.sidebar")
local Motion = require("beat.app.services.motion")

---@param reduceMotion boolean?
local function make(reduceMotion)
	local settings = { values = { reduceMotion = reduceMotion == true }, changed = function() end }
	local motion = Motion.new({ settings = settings })
	local service = Sidebar.new({ collections = {}, messages = { connect = function() end }, motion = motion })
	return service, motion, settings
end

local WIDTH = 264
local COLLAPSED = 76

test.it("eases the rail from its old width to the new form and settles", function()
	local service, motion = make()
	test.equal(service:width(WIDTH, false, 0), WIDTH, "the first frame settles on the width the settings ask for")

	local started = service:width(COLLAPSED, true, 1)
	test.equal(started, WIDTH, "the first frame of a transition is where the rail was")

	local widths, distinct, count = {}, {}, 0
	local at = 1
	for _ = 1, 60 do
		at = at + 1 / 60
		local width = service:width(COLLAPSED, true, at)
		widths[#widths + 1] = width
		if not distinct[width] then
			distinct[width] = true
			count = count + 1
		end
		motion:step(at)
	end

	test.truthy(widths[1] > COLLAPSED and widths[1] < WIDTH, "the rail is part way over")
	test.equal(service:width(COLLAPSED, true, at), COLLAPSED, "the transition ends on the target width")
	test.truthy(count <= 13, "a transition builds a dozen styles, not one a frame: " .. count)

	local changed, busy = motion:step(at + 0.5)
	test.falsy(busy, "the ticker is idle once the rail has settled")
	test.falsy(changed, "and nothing asks for another frame")
end)

test.it("keeps the ticker busy while the rail is moving", function()
	local service, motion = make()
	service:width(WIDTH, false, 0)
	service:width(COLLAPSED, true, 1)

	local changed, busy = motion:step(1)
	test.truthy(changed, "the transition asks for a rebuilt frame")
	test.truthy(busy, "and asks to come back next frame")

	local midChanged, midBusy = motion:step(1.1)
	test.truthy(midChanged)
	test.truthy(midBusy)

	local endChanged, endBusy = motion:step(1.19)
	test.truthy(endChanged, "the last frame of the transition is drawn")
	test.truthy(endBusy, "and is the frame that shows its end")

	local idleChanged, idleBusy = motion:step(1.2)
	test.falsy(idleChanged)
	test.falsy(idleBusy, "nothing is moving any more")
end)

test.it("turns around from where the rail is when toggled again", function()
	local service, motion = make()
	service:width(WIDTH, false, 0)
	service:width(COLLAPSED, true, 1)
	motion:step(1.1)

	local mid = service:width(COLLAPSED, true, 1.1)
	test.truthy(mid > COLLAPSED and mid < WIDTH, "the rail is part way over")

	local back = service:width(WIDTH, false, 1.1)
	test.equal(back, mid, "a second toggle starts from the width on screen, not a jump")

	local at = 1.1
	for _ = 1, 60 do
		at = at + 1 / 60
		service:width(WIDTH, false, at)
		motion:step(at)
	end
	test.equal(service:width(WIDTH, false, at), WIDTH, "and settles back on the wide form")
	local _, busy = motion:step(at + 0.5)
	test.falsy(busy)
end)

test.it("sets the width directly while the grip is dragged", function()
	local service, motion = make()
	service:width(WIDTH, false, 0)

	test.equal(service:width(300, false, 1), 300, "a dragged width is where the rail goes")
	local _, busy = motion:step(1)
	test.falsy(busy, "a drag is not a transition")
end)

test.it("settles at once when motion is reduced", function()
	local service, motion = make(true)
	service:width(WIDTH, false, 0)

	test.equal(service:width(COLLAPSED, true, 1), COLLAPSED, "the rail is already narrow")
	local changed, busy = motion:step(1)
	test.falsy(changed)
	test.falsy(busy, "nothing animates with reduce motion on")
end)

-- The narrow rail draws its icons in the middle of the rail rather than at the wide rail's left
-- inset, and a playlist's artwork sits inside the row's hover box instead of over its edge. The
-- frame exposes both through the layout, so these tests read the nodes the rail drew.
local canRender = true
do
	local ok = pcall(function()
		local wonderland = require("wonderland")
		wonderland.headless.new(|| -> wonderland.div(), { width = 8, height = 8 }):close()
	end)
	canRender = ok
end

--- Draws the rail on its own at each width in `sides`, from one app, and calls `visit` with the
--- frame's layout for each. A side is passed rather than waited for, so a test can be the middle
--- of the opening animation as well as either end of it.
---@param sides number[]
---@param visit fun(side: number, ctx: any, tree: any, app: beat.App)
local function eachRail(sides, visit)
	local fs = require("fs")
	local wonderland = require("wonderland")
	local paths = require("beat.paths")
	local Library = require("beat.music.library")
	local Taxonomy = require("beat.app.services.collections.taxonomy")
	local App = require("beat.app")

	local directory = os.tmpname() .. "-beat-sidebar-rail"
	os.remove(directory)
	fs.mkdirAll(directory)
	local realDirectory = paths.directory
	paths.directory = || -> directory

	local ok, err = pcall(function()
		App:init({ scan = false })
		App.services.settings.values.root = "/beat-fixtures"
		App.services.settings.values.sidebarWidth = 264
		App.services.settings.values.sidebarCollapsed = true
		App.services.settings.values.reduceMotion = true
		App.services.library.current = Library.new("/beat-fixtures")
		App.services.collections.taxonomy = Taxonomy.new()
		App.services.collections.taxonomy:addPlaylist("Night Mix", false)
		App.page = { kind = "home" }

		for _, side in ipairs(sides) do
			local screen = wonderland.headless.new(function(window, assets)
				App.window = window
				App.assets = assets
				App.services.covers:use(assets)
				return require("beat.app.components.chrome.sidebar").view(App, { width = 1200, height = 688, ui = App:ui(window), side = side })
			end, { width = side, height = 688 })
			App.layoutPlugin = screen.plugins.layout
			screen:draw()
			screen:draw()

			local layout = screen:getPlugin("layout")
			local ctx
			for _, context in pairs(layout.contexts) do ctx = context end
			visit(side, ctx, ctx.screen, App)
			screen:close()
		end

		App.services.playback.player:close()
		App.layoutPlugin = nil
	end)

	paths.directory = realDirectory
	fs.rmdir(directory)
	if not ok then error(err) end
end

test.skipIf(not canRender)("centres the collapsed rail's marks inside their rows", function()
	local utf8 = require("utf8")
	local elements = require("wonderland.element")

	eachRail({ 76 }, function(side, ctx, tree, app)
		local theme = app.services.appearance.theme
		local railWidth = theme:px(76)
		local railPad = theme:px(16)
		local middle = railWidth / 2
		-- The narrow rail's artwork leaves room for the hover box around it: the 44 px row less
		-- 6 px of background on each side.
		local artSize = railWidth - railPad * 2 - theme:px(12)
		local homeGlyph = utf8.char(0xE00A)
		local iconX, iconWidth
		local artX, artWidth
		local brandX, brandWidth

		local function walk(index, parentX, parentY, parentWidth)
			local node = tree:node(index)
			local x, y = parentX + node.x, parentY + node.y
			local element = elements.pointers[node.element]
			local value = element ~= nil and elements.textOf(element) or nil
			if value == homeGlyph and iconX == nil then
				iconX, iconWidth = parentX, parentWidth
			elseif brandX == nil and node.width == theme:px(22) and node.height == theme:px(22) and y < theme:px(52) then
				brandX, brandWidth = x, node.width
			end
			if artX == nil and node.width == artSize and node.height == artSize then
				artX, artWidth = x, node.width
			end
			for child = 0, node.childCount - 1 do
				local nextIndex = tree.childIndices[node.firstChild + child - 1]
				if nextIndex ~= nil then walk(nextIndex, x, y, node.width) end
			end
		end
		walk(ctx.root, 0, 0, 0)

		test.truthy(iconX ~= nil, "the home icon is drawn")
		if iconX ~= nil then
			test.truthy(math.abs(iconX + iconWidth / 2 - middle) <= 1, "the icon is centred in the rail: " .. (iconX + iconWidth / 2))
		end
		test.truthy(brandX ~= nil, "the brand mark is drawn")
		if brandX ~= nil then
			test.truthy(math.abs(brandX + brandWidth / 2 - middle) <= 1, "the brand mark is centred in the rail: " .. (brandX + brandWidth / 2))
		end
		test.truthy(artX ~= nil, "a playlist's artwork is drawn")
		if artX ~= nil then
			test.truthy(artX >= railPad, "the artwork starts inside the row's left inset")
			test.truthy(artX + artWidth <= railWidth - railPad, "the artwork ends inside the row's right inset")
			test.truthy(math.abs(artX + artWidth / 2 - middle) <= 1, "the artwork is centred in the rail: " .. (artX + artWidth / 2))
		end
	end)
end)

test.skipIf(not canRender)("leaves room around the collapsed rail's artwork inside its hover box", function()
	eachRail({ 76 }, function(side, ctx, tree, app)
		local theme = app.services.appearance.theme
		local railPad = theme:px(16)
		local railWidth = theme:px(76)
		local inset = theme:px(6)
		local artSize = railWidth - railPad * 2 - theme:px(12)
		local rows, squares, seen = {}, {}, {}

		local function walk(index, parentX, parentY)
			local node = tree:node(index)
			local x, y = parentX + node.x, parentY + node.y
			if node.height == theme:px(52) and y > theme:px(240) then
				rows[#rows + 1] = { x = x, y = y, width = node.width }
			end
			if node.width == artSize and node.height == artSize and y > theme:px(240) then
				local key = x .. ":" .. y
				if not seen[key] then
					seen[key] = true
					squares[#squares + 1] = { x = x, y = y, width = node.width }
				end
			end
			for child = 0, node.childCount - 1 do
				local nextIndex = tree.childIndices[node.firstChild + child - 1]
				if nextIndex ~= nil then walk(nextIndex, x, y) end
			end
		end
		walk(ctx.root, 0, 0)

		test.truthy(#rows >= 2, "the playlist row and the create row are drawn")
		test.truthy(#squares >= 2, "the playlist's artwork and the create tile's square are drawn")
		if #rows < 2 or #squares < 2 then return end
		local playlistRow, createRow = rows[1], rows[2]
		local art, plus = squares[1], squares[2]
		test.truthy(art.x - playlistRow.x >= inset, "the artwork keeps 6 px of hover background on its left")
		test.truthy(playlistRow.x + playlistRow.width - (art.x + art.width) >= inset, "and on its right")
		test.truthy(plus.x - createRow.x >= inset, "the create tile keeps 6 px of hover background on its left")
		test.truthy(createRow.x + createRow.width - (plus.x + plus.width) >= inset, "and on its right")
	end)
end)

test.skipIf(not canRender)("keeps every row's content inside its box while the rail opens", function()
	eachRail({ 90, 110, 130, 160, 200, 264 }, function(side, ctx, tree)
		local overflow
		local function check(index, x, y)
			local node = tree:node(index)
			local nx, ny = x + node.x, y + node.y
			local left = nx + node.paddingLeft
			local right = nx + node.width - node.paddingRight
			for child = 0, node.childCount - 1 do
				local ci = tree.childIndices[node.firstChild + child - 1]
				local childNode = tree:node(ci)
				local cx = nx + childNode.x
				if childNode.width > 0 or childNode.height > 0 then
					if cx < left - 1 then
						overflow = overflow or ("a child at " .. cx .. " starts before the row's " .. left)
					elseif cx + childNode.width > right + 1 then
						overflow = overflow or ("a child ending at " .. (cx + childNode.width) .. " passes the row's " .. right)
					end
					check(ci, nx, ny)
				end
			end
		end
		check(ctx.root, 0, 0)
		test.equal(overflow, nil, "the rail's contents stay inside their boxes at " .. side .. (overflow and (": " .. overflow) or ""))
	end)
end)

-- The expanded rail's playlist rows share the navigation rows' box: the hover fill of a playlist
-- starts and ends where Home's does, and its artwork keeps the same inner inset. The two rows are
-- built by different calls, so this is the frame's layout that says they agree.
test.skipIf(not canRender)("gives the expanded playlist rows the navigation rows' box and inset", function()
	eachRail({ 264 }, function(side, ctx, tree, app)
		local theme = app.services.appearance.theme
		local nav, playlist, art
		local function walk(index, parentX, parentY)
			local node = tree:node(index)
			local x, y = parentX + node.x, parentY + node.y
			if nav == nil and node.height == theme:px(42) and y < theme:px(200) then
				nav = { x = x, y = y, width = node.width, paddingLeft = node.paddingLeft, paddingRight = node.paddingRight }
			elseif playlist == nil and node.height == theme:px(52) and y > theme:px(240) then
				playlist = { x = x, y = y, width = node.width, paddingLeft = node.paddingLeft, paddingRight = node.paddingRight }
			end
			if art == nil and node.width == theme:px(40) and node.height == theme:px(40) and y > theme:px(240) then
				art = { x = x, y = y, width = node.width }
			end
			for child = 0, node.childCount - 1 do
				local nextIndex = tree.childIndices[node.firstChild + child - 1]
				if nextIndex ~= nil then walk(nextIndex, x, y) end
			end
		end
		walk(ctx.root, 0, 0)

		test.truthy(nav ~= nil, "the Home navigation row is drawn")
		test.truthy(playlist ~= nil, "a playlist row is drawn")
		if nav == nil or playlist == nil then return end
		test.equal(playlist.x, nav.x, "the playlist row starts where the Home row starts")
		test.equal(playlist.width, nav.width, "the playlist row is as wide as the Home row")
		test.equal(playlist.paddingLeft, nav.paddingLeft, "the playlist row keeps the Home row's left inset")
		test.equal(playlist.paddingRight, nav.paddingRight, "the playlist row keeps the Home row's right inset")
		test.truthy(art ~= nil, "the playlist's artwork is drawn")
		if art ~= nil then
			test.equal(art.x, playlist.x + playlist.paddingLeft, "the artwork starts at the row's inner edge")
			test.truthy(art.x + art.width <= playlist.x + playlist.width - playlist.paddingRight, "the artwork ends inside the row's right inset")
		end
	end)
end)
