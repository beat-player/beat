-- The press mark: a ring that grows from where the button went down, inside the control's rounded
-- box, and the reduced-motion version that lights the box instead. The clock is handed to the
-- module in these tests -- a press and a step at a time a test names -- so a ripple is followed
-- through its whole life without sleeping; the two screens at the end are what say the mark is
-- drawn where the press was and not outside the control it belongs to.
local test = require("lde-test")
local wonderland = require("wonderland")
local ui = require("beat-ui")
local ripple = require("beat-ui.ripple")

local time = wonderland.time

local EXPAND, FADE = 0.32, 0.18

local canRender = true
do
	local ok = pcall(function()
		wonderland.headless.new(function() return wonderland.div() end, { width = 8, height = 8 }):close()
	end)
	canRender = ok
end

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
	accentInk = "#0a0c08"
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
---@return beat.ui.Context
local function context(width)
	return ui.Context.new({
		theme = THEME,
		assets = nil,
		width = width or 800,
		height = 600,
		contentWidth = (width or 800) - 100,
		contentHeight = 600 - 64,
		mobile = (width or 800) < 640,
		focusedId = nil
	})
end

--- A control that is only a press mark: what the module is handed by a component, without a screen.
---@param key any
---@return wonderland.Element
local function control(key)
	local element = wonderland.div()
	return ripple.attach(element, key, "#f4f6f9")
end

test.afterEach(function()
	ripple.reset()
end)

test.it("a press starts a mark where it landed, as big as the farthest corner", function()
	control("one")
	local slot = assert(ripple.press("one", 10, 5, 100, 40, true, 100.0))

	test.equal(slot.x, 10, "the origin is the place in the control the press was")
	test.equal(slot.y, 5)
	test.equal(slot.width, 100)
	test.equal(slot.height, 40)
	test.equal(slot.alpha, 0.12, "a finger is the full mark")
	test.equal(slot.flat, false)

	-- The corner the press is farthest from, and one pixel past it so the last row is covered.
	local expected = math.sqrt(math.max(10, 90) ^ 2 + math.max(5, 35) ^ 2) + 1
	test.truthy(math.abs(slot.radius - expected) < 1e-9, "the mark reaches the farthest corner")
end)

test.it("a mouse press leaves half the ink of a finger", function()
	control("mouse")
	local slot = assert(ripple.press("mouse", 4, 4, 80, 32, false, 100.0))
	test.equal(slot.alpha, 0.06)
end)

test.it("a mark is busy while it grows and fades, and frees its slot after", function()
	control("life")
	local slot = assert(ripple.press("life", 10, 10, 80, 40, true, 100.0))

	local active, ended = ripple.advance(100.1)
	test.equal(active, 1, "the mark is still running")
	test.equal(ended, false, "and nothing was freed")
	test.truthy(ripple.busy())

	active, ended = ripple.advance(100.0 + EXPAND + FADE - 0.001)
	test.equal(active, 1, "the last instant before the fade is over is still a mark")
	test.equal(ended, false)

	active, ended = ripple.advance(100.0 + EXPAND + FADE)
	test.equal(active, 0)
	test.equal(ended, true, "the frame that ends it is owed a rebuild")
	test.equal(slot.free, true, "the slot is free again")
	test.equal(ripple.slot("life"), nil, "and the control no longer has one")
	test.equal(ripple.busy(), false)
end)

test.it("a tap grows to the end before it fades, and a hold fades from where it was let go", function()
	control("tap")
	local tap = assert(ripple.press("tap", 4, 4, 80, 40, true, 100.0))
	ripple.release("tap", 100.05)
	test.equal(tap.fadeAt, 100.0 + EXPAND, "a press let go of at once still expands all the way")
	test.equal(tap.endAt, 100.0 + EXPAND + FADE)

	control("hold")
	local hold = assert(ripple.press("hold", 4, 4, 80, 40, true, 200.0))
	ripple.release("hold", 200.4)
	test.equal(hold.fadeAt, 200.4, "a press held past the expansion fades from the release")
	test.equal(hold.endAt, 200.4 + FADE)
end)

test.it("reduced motion lights the box for a moment instead of growing a circle", function()
	ripple.reduced = true
	control("flat")
	local slot = assert(ripple.press("flat", 4, 4, 80, 40, true, 100.0))

	test.equal(slot.flat, true)
	test.equal(slot.fadeAt, 100.1, "the highlight holds for a moment")
	test.equal(slot.endAt, 100.1 + 0.16, "and fades rather than growing")
end)

test.it("a busy screen reuses the slot that ends first", function()
	local keys = { "a", "b", "c", "d", "e", "f", "g" }
	for at = 1, #keys do control(keys[at]) end

	local first
	for at = 1, #keys do
		local slot = assert(ripple.press(keys[at], 2, 2, 40, 20, true, 100.0 + at))
		if at == 1 then first = slot end
	end

	test.equal(first.free, false, "the slot itself is reused rather than freed")
	test.equal(ripple.slot("a"), nil, "the mark that was running longest made way")
	test.truthy(ripple.slot("g") ~= nil, "the newest press has a mark")
	test.equal(ripple.slot("g"), first, "in the slot that had the least time left")
	test.truthy(ripple.busy())
end)

test.it("a place in the screen gives its mark up when the app moves on, a key of its own does not", function()
	local placed = wonderland.div()
	ripple.attach(placed, nil, "#f4f6f9")
	control("sidebar.home")

	assert(ripple.press(placed.index, 2, 2, 40, 20, true, 100.0))
	assert(ripple.press("sidebar.home", 2, 2, 40, 20, true, 100.0))

	test.equal(ripple.clearVolatile(), 1, "only the mark held by a place in the screen goes")
	test.equal(ripple.slot(placed.index), nil)
	test.truthy(ripple.slot("sidebar.home") ~= nil, "a named control keeps its mark across a page")
end)

---@param pixels string
---@param width number
---@param x number
---@param y number
---@return number, number, number, number
local function pixelAt(pixels, width, x, y)
	local at = (y * width + x) * 4 + 1
	return pixels:byte(at), pixels:byte(at + 1), pixels:byte(at + 2), pixels:byte(at + 3)
end

--- A button alone at the screen's corner: what the marks below are sampled from is the button's own
--- coordinates, and its box is the screen's corner.
---@param key string
---@return wonderland.Headless, string
local function buttonScreen(key)
	local ctx = context()
	local screen = wonderland.headless.new(function()
		return wonderland.div():style(wonderland.sty():column()):children({
			ui.button(ctx, { label = "Tap", width = 160, height = 48, key = key, onClick = { type = "tap" } })
		})
	end, { width = 200, height = 120 })
	screen:draw()

	return screen, key
end

test.skipIf(not canRender)("a press event tells the button's mark where the press was", function()
	local screen, key = buttonScreen("layout.button")
	test.equal(ripple.slot(key), nil, "nothing is pressed yet")

	-- The pointer is moved first so the button is hovered for the baseline below, as it is for the
	-- press: the two frames differ in the mark and nothing else.
	screen:event({ name = "mouseMove", window = screen.window, x = 20, y = 24 })
	screen:draw()
	local before = assert(screen:getPixels())

	screen:event({ name = "mousePress", window = screen.window, x = 20, y = 24, button = 1 })
	local slot = assert(ripple.slot(key), "the press started a mark on the button")
	test.equal(slot.x, 20, "at the place in the button the pointer went down")
	test.equal(slot.y, 24)
	test.equal(slot.width, 160, "and the button's own box")
	test.equal(slot.height, 48)
	test.equal(slot.alpha, 0.06, "a mouse is the quieter mark")

	-- Draw a late frame of it: the circle has reached every corner, and the rounded box is what
	-- keeps it out of the one the pointer is far from.
	ripple.press(key, 20, 24, 160, 48, false, time.now() - EXPAND)
	screen:draw()
	local after = assert(screen:getPixels())
	test.truthy(after ~= nil)

	local r0, g0, b0 = pixelAt(before, 200, 30, 24)
	local r1, g1, b1 = pixelAt(after, 200, 30, 24)
	test.truthy(r1 ~= r0 or g1 ~= g0 or b1 ~= b0, "the mark is drawn inside the button")

	local cr0, cg0, cb0 = pixelAt(before, 200, 1, 1)
	local cr1, cg1, cb1 = pixelAt(after, 200, 1, 1)
	test.equal(cr1, cr0, "the rounded corner is not painted")
	test.equal(cg1, cg0)
	test.equal(cb1, cb0)

	screen:close()
end)

test.skipIf(not canRender)("a finger's press is the stronger mark and reduced motion lights the box", function()
	local screen, key = buttonScreen("layout.touch")
	screen:event({ name = "mousePress", window = screen.window, x = 80, y = 24, button = 1, touch = true })
	local slot = assert(ripple.slot(key))
	test.equal(slot.alpha, 0.12, "the screen said a finger made it")

	ripple.reset()
	ripple.reduced = true

	local flatScreen, flatKey = buttonScreen("layout.flat")
	flatScreen:click(80, 24)
	local flat = assert(ripple.slot(flatKey), "a press with reduced motion still shows something")
	test.equal(flat.flat, true)
	test.truthy(flat.endAt - flat.start < 0.3, "and it is over quickly")

	flatScreen:close()
	screen:close()
end)

test.skipIf(not canRender)("the reduced-motion highlight covers the button's whole box", function()
	local screen, key = buttonScreen("pixels.flat")
	ripple.reduced = true
	screen:event({ name = "mouseMove", window = screen.window, x = 80, y = 24 })
	screen:draw()
	local before = assert(screen:getPixels())

	-- A press just now: the highlight holds at full strength for its first tenth of a second.
	ripple.press(key, 80, 24, 160, 48, true, time.now())
	-- And a draw of the frame the rebuild attaches the mark to reads the clock of that frame, which
	-- is a moment later: that is still inside the hold.
	screen:draw()
	local after = assert(screen:getPixels())

	local r0, g0, b0 = pixelAt(before, 200, 8, 8)
	local r1, g1, b1 = pixelAt(after, 200, 8, 8)
	test.truthy(r1 ~= r0 or g1 ~= g0 or b1 ~= b0, "the padding is lit as well as the label's room")

	screen:close()
end)
