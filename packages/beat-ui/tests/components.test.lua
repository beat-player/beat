-- What a plugin can rely on when it draws with beat-ui: a button is as wide as its label when no
-- width is given, a check box shows its state and sends its message, a progress bar clamps its
-- value and draws both determinate and indeterminate forms, and a card is its content plus its
-- padding. The screens are headless, so the pictures are the test.
local test = require("lde-test")
local wonderland = require("wonderland")
local utf8 = require("utf8")
local elements = require("wonderland.element")
local ui = require("beat-ui")
local progressBar = require("beat-ui.progress_bar")

local canRender = true
do
	local ok = pcall(function()
		wonderland.headless.new(function() return wonderland.div() end, { width = 8, height = 8 }):close()
	end)
	canRender = ok
end

-- A theme with the tokens and sizes components ask for. It is not beat's theme: beat-ui must work
-- with anything that has the documented interface.
local THEME = {
	accentInk = "#0a0c08",
	name = "night",
	accent = "lime",
	isDark = true,
	accentColour = "#c9f45b",
	fontFamily = "Inter",
	scale = 1
}

local COLOURS = {
	bg = "#0b0c10",
	surface = "#14161b",
	elevated = "#1b1e24",
	hover = "#23272f",
	active = "#2a2f38",
	text = "#f4f6f9",
	muted = "#9aa3b2",
	faint = "#6f7786",
	border = "#ffffff12",
	accent = "#c9f45b",
	accentInk = "#0a0c08",
	danger = "#ff6b6b",
	success = "#7ee787",
	warning = "#ffc857"
}

local TYPES = { xs = 12, sm = 13, base = 14, md = 15, lg = 19, xl = 24, xxl = 30, hero = 46 }
local RADII = { sm = 6, md = 8, lg = 10, xl = 14, hero = 20, full = 999 }

function THEME:color(token)
	return COLOURS[token] or token
end
function THEME:px(value)
	return value
end
function THEME:space(value)
	return value
end
function THEME:type(name)
	return TYPES[name] or TYPES.base
end
function THEME:radius(name)
	return RADII[name] or RADII.md
end
function THEME:s()
	return wonderland.sty()
end

---@param width number?
---@param mobile boolean?
local function context(width, mobile)
	return ui.Context.new({
		theme = THEME,
		assets = nil,
		width = width or 800,
		height = 600,
		contentWidth = (width or 800) - 100,
		contentHeight = 600 - 64,
		mobile = mobile == true,
		focusedId = nil
	})
end

--- The layout context of a headless screen and the index of its root node.
---@param screen wonderland.Headless
---@return table
---@return number
local function laidOut(screen)
	local layout = screen:getPlugin("layout")
	local ctx
	for _, value in pairs(layout.contexts) do ctx = value end
	assert(ctx, "the screen was laid out")
	return ctx --[[@as table]], ctx.root --[[@as number]]
end

--- The first node in the tree whose element's text is `value`, with its absolute size.
---@param ctx table
---@param index number
---@param value string
local function findText(ctx, index, value)
	local node = ctx.screen:node(index)
	local element = elements.pointers[node.element]
	if element ~= nil and elements.textOf(element) == value then return node end
	for child = 0, node.childCount - 1 do
		local childIndex = ctx.screen.childIndices[node.firstChild + child - 1] --[[@as number?]]
		if childIndex ~= nil then
			local found = findText(ctx, childIndex, value)
			if found ~= nil then return found end
		end
	end
	return nil
end

--- The first node named `name`, wherever it is in the tree.
---@param ctx table
---@param index number
---@param name string
local function findNamed(ctx, index, name)
	local node = ctx.screen:node(index)
	local element = elements.pointers[node.element]
	if element ~= nil and elements.nameOf(element) == name then return node end
	for child = 0, node.childCount - 1 do
		local childIndex = ctx.screen.childIndices[node.firstChild + child - 1] --[[@as number?]]
		if childIndex ~= nil then
			local found = findNamed(ctx, childIndex, name)
			if found ~= nil then return found end
		end
	end
	return nil
end

test.it("a context exposes the theme, the window box and the panel gutter", function()
	local wide = context(800, false)
	test.equal(wide:color("accent"), "#c9f45b")
	test.equal(wide:px(12), 12)
	test.equal(wide:space(16), 16)
	test.equal(wide:type("lg"), 19)
	test.equal(wide:radius("sm"), 6)
	test.equal(wide.contentWidth, 700)
	test.equal(wide:panelWidth(500), 500, "a panel narrower than the window is its own width")

	local phone = context(500, true)
	test.equal(phone:panelWidth(600), 468, "a phone keeps a gutter on both sides")
end)

test.skipIf(not canRender)("a button sizes to its label when it has no width", function()
	local ctx = context()
	local screen = wonderland.headless.new(function()
		local button = ui.button(ctx, { label = "Save", onClick = { type = "save" } }):named("button")
		return wonderland.div():style(wonderland.sty():column():align("start")):children({ button })
	end, { width = 400, height = 100 })
	screen:draw()
	local screenCtx, rootIndex = laidOut(screen)
	local root = assert(findNamed(screenCtx, rootIndex, "button"), "the button was laid out")
	test.truthy(findText(screenCtx, rootIndex, "Save") ~= nil, "the label was laid out")
	local measure = require("beat-ui.measure")
	local expected = measure.estimate("Save", 13, 0.48) + 32
	test.equal(root.width, expected, "the width is the label estimate plus the horizontal padding")
	test.equal(root.height, 36, "the default height is px(36)")
	screen:close()
end)

test.skipIf(not canRender)("a check box draws its state and sends its message", function()
	local message = { type = "pluginEnabled", file = "one.lua", enabled = true }
	local ctx = context()
	local screen = wonderland.headless.new(function()
		return ui.checkbox(ctx, { checked = true, onClick = message })
	end, { width = 100, height = 100 })
	screen:draw()
	local ctx, rootIndex = laidOut(screen)
	local root = ctx.screen:node(rootIndex)
	local glyph = utf8.char(0xE012)
	test.truthy(findText(ctx, rootIndex, glyph) ~= nil, "a checked box draws the check glyph")
	local sent
	screen.onMessage = function(value) sent = value end
	screen:click(root.width / 2, root.height / 2)
	test.equal(sent, message, "a click sends the message it was given")
	screen:close()

	local uncheckedCtx = context()
	local second = wonderland.headless.new(function()
		return ui.checkbox(uncheckedCtx, { checked = false, onClick = message })
	end, { width = 100, height = 100 })
	second:draw()
	local uncheckedCtx, uncheckedRoot = laidOut(second)
	test.equal(findText(uncheckedCtx, uncheckedRoot, glyph), nil, "an unchecked box draws no glyph")
	second:close()
end)

test.it("a progress value is clamped to the track", function()
	test.equal(progressBar.fraction(2), 1)
	test.equal(progressBar.fraction(-1), 0)
	test.equal(progressBar.fraction(0.42), 0.42)
	test.equal(progressBar.fraction(nil), nil)
	test.equal(progressBar.fraction(0 / 0), nil)
end)

--- Draws a progress bar's canvas into a recording canvas and returns its rectangles.
---@param ctx beat.ui.Context
---@param props beat.ui.ProgressBarProps
local function rectangles(ctx, props)
	local bar = ui.progressBar(ctx, props)
	local handle = bar.oncanvas --[[@as number]]
	local callbacks = elements.callbacks --[[@as table<number, fun(canvas: wonderland.Canvas): any>]]
	local draw = callbacks[handle]
	---@type { x: number, y: number, width: number, height: number, colour: string, radius: number }[]
	local rects = {}
	draw({
		width = props.width,
		height = 4,
		rect = function(_, x, y, width, height, colour, radius)
			rects[#rects + 1] = { x = x, y = y, width = width, height = height, colour = colour, radius = radius }
		end
	} --[[@as wonderland.Canvas]])
	return rects
end

test.it("a determinate bar clamps both ends and an indeterminate one draws a band", function()
	local full = rectangles(context(), { value = 2, width = 100, height = 4 })
	test.equal(#full, 2, "the track and a fill")
	test.equal(full[2].width, 100, "a value over one fills the track")

	local empty = rectangles(context(), { value = -1, width = 100, height = 4 })
	test.equal(#empty, 1, "a value under zero leaves the track empty")

	local realNow = wonderland.time.now
	wonderland.time.now = function() return 0.5 end
	local moving = rectangles(context(), { indeterminate = true, width = 100, height = 4 })
	wonderland.time.now = realNow
	test.equal(#moving, 2, "an indeterminate bar draws the moving band")
	test.greater(moving[2].width, 0)
	test.truthy(moving[2].width < 100, "the band is narrower than the track")
end)

test.skipIf(not canRender)("a field without a width stays inside its padded parent", function()
	local ctx = context()
	local screen = wonderland.headless.new(function()
		local field = ui.field(ctx, {
			name = "field",
			value = "",
			placeholder = "A field",
			oninput = function() end,
			onsubmit = function() end
		}):named("field")
		return wonderland.div():style(wonderland.sty():column():w(300):pad(20)):children({ field })
	end, { width = 400, height = 100 })
	screen:draw()
	local screenCtx, rootIndex = laidOut(screen)
	local field = assert(findNamed(screenCtx, rootIndex, "field"), "the field was laid out")
	test.equal(field.x, 20, "the field starts at the parent's padding")
	test.equal(field.width, 260, "and fills the parent's content box, not its border box")
	test.truthy(field.x + field.width <= 300, "the field stays inside the parent")
	screen:close()
end)

test.skipIf(not canRender)("a card puts its content inside its padding", function()
	local ctx = context()
	local screen = wonderland.headless.new(function()
		local child = wonderland.div():style(wonderland.sty():h(20)):named("content")
		local card = ui.card(ctx, { children = { child }, height = 56, padding = 18, gap = 12 }):named("card")
		return wonderland.div():style(wonderland.sty():column():align("start")):children({ card })
	end, { width = 400, height = 100 })
	screen:draw()
	local screenCtx, rootIndex = laidOut(screen)
	local card = assert(findNamed(screenCtx, rootIndex, "card"), "the card was laid out")
	local content = assert(findNamed(screenCtx, rootIndex, "content"), "the content was laid out")
	test.equal(card.height, 56, "the caller's height is the card's")
	test.equal(content.y, 18, "the content starts inside the top padding")
	test.equal(content.height, 20, "and keeps its own height")
	screen:close()
end)

--- How many nodes in the tree draw exactly `value`.
---@param ctx table
---@param index number
---@param value string
local function countText(ctx, index, value)
	local node = ctx.screen:node(index)
	local element = elements.pointers[node.element]
	local count = (element ~= nil and elements.textOf(element) == value) and 1 or 0
	for child = 0, node.childCount - 1 do
		local childIndex = ctx.screen.childIndices[node.firstChild + child - 1] --[[@as number?]]
		if childIndex ~= nil then count = count + countText(ctx, childIndex, value) end
	end
	return count
end

test.skipIf(not canRender)("a rating draws its stars and sets or takes back a rating", function()
	local ctx = context()
	local screen = wonderland.headless.new(function()
		return wonderland.div():style(wonderland.sty():column():align("start")):children({
			ui.rating(ctx, { value = 3, onRate = function(stars) return { stars = stars } end, size = 20, gap = 0 })
		})
	end, { width = 200, height = 40 })
	screen:draw()
	local screenCtx, rootIndex = laidOut(screen)
	test.equal(countText(screenCtx, rootIndex, utf8.char(0xE01B)), 3, "three set stars")
	test.equal(countText(screenCtx, rootIndex, utf8.char(0xE01C)), 2, "and two empty ones")

	local sent
	screen.onMessage = function(value) sent = value end
	screen:click(30, 10)
	test.equal(sent.stars, 2, "a lower star sets that many")
	screen:click(90, 10)
	test.equal(sent.stars, 5, "a higher one too")
	screen:click(50, 10)
	test.equal(sent.stars, 0, "the star at the rating takes it back")
	screen:close()
end)
