-- The clock side of the press marks: the app is kept awake while one is growing and let back to
-- sleep when it is gone, the reduced-motion setting is what the marks read, and a mark held by a
-- place in the screen goes when the screen does.
local test = require("lde-test")
local wonderland = require("wonderland")
local ripple = require("beat-ui.ripple")
local Ripple = require("beat.app.services.ripple")

---@class RippleTestApp
---@field page table
---@field overlays table[]

---@param reduceMotion boolean?
---@return beat.RippleService, { values: { reduceMotion: boolean } }, RippleTestApp
local function service(reduceMotion)
	local settings = { values = { reduceMotion = reduceMotion == true } }
	---@type RippleTestApp
	local app = { page = { kind = "home" }, overlays = {} }

	return Ripple.new({ settings = settings, app = app }), settings, app
end

--- A control that is only a press mark, as a component hands one over.
---@param key any
local function control(key)
	return ripple.attach(wonderland.div(), key, "#f4f6f9")
end

test.afterEach(function()
	ripple.reset()
end)

test.it("a tick with nothing pressed asks for nothing", function()
	local clock = 100.0
	local subject = service()
	local changed, busy = subject:step(clock)
	test.equal(changed, nil)
	test.equal(busy, nil, "an idle app is not woken at the frame rate")
end)

test.it("a running mark keeps the tick at the frame rate, and the frame that ends it is drawn", function()
	local clock = 100.0
	local subject = service()
	control("keyed")
	assert(ripple.press("keyed", 4, 4, 80, 40, true, clock))

	local changed, busy, repaint = subject:step(clock + 0.05)
	test.equal(changed, true, "the press is the frame the mark's draw is attached on")
	test.equal(busy, true, "and the ticker comes back at the frame rate")
	test.equal(repaint, nil)

	changed, busy, repaint = subject:step(clock + 0.1)
	test.equal(changed, false, "a frame of the same screen is not built again")
	test.equal(busy, true)
	test.equal(repaint, true, "the draw of the mark is what moves")

	clock = clock + 0.6
	changed, busy = subject:step(clock)
	test.equal(changed, true, "the frame that frees the slot is owed a rebuild")
	test.equal(busy, false, "and nothing is moving after it")

	changed, busy = subject:step(clock + 3)
	test.equal(changed, nil, "then the app sleeps again")
	test.equal(busy, nil)
end)

test.it("the reduced-motion setting is what the marks read", function()
	local subject, settings = service(true)
	test.equal(ripple.reduced, true, "a service made with the setting on starts that way")

	control("flat")
	assert(ripple.press("flat", 4, 4, 80, 40, true, 100.0))
	test.equal(ripple.slot("flat").flat, true)

	settings.values.reduceMotion = false
	subject:step(100.05)
	test.equal(ripple.reduced, false, "a change of the setting is picked up on the next tick")
end)

test.it("a mark held by a place in the screen goes when the page does, a named one stays", function()
	local clock = 100.0
	local subject = service()
	subject:step(clock)

	local placed = wonderland.div()
	ripple.attach(placed, nil, "#f4f6f9")
	control("sidebar.home")

	assert(ripple.press(placed.index, 2, 2, 40, 20, true, clock))
	assert(ripple.press("sidebar.home", 2, 2, 40, 20, true, clock))

	local app = subject.app
	app.page = { kind = "library" }
	subject:step(clock + 0.05)

	test.equal(ripple.slot(placed.index), nil, "another page has another control in that place")
	test.truthy(ripple.slot("sidebar.home") ~= nil, "the rail is still the rail")
end)

test.it("opening a panel clears the marks drawn under it", function()
	local clock = 100.0
	local subject = service()
	subject:step(clock)

	local row = wonderland.div()
	ripple.attach(row, nil, "#f4f6f9")
	assert(ripple.press(row.index, 2, 2, 40, 20, true, clock))

	subject.app.overlays[1] = { name = "menu" }
	subject:step(clock + 0.05)

	test.equal(ripple.slot(row.index), nil, "the mark of a control under a panel is not the panel's")
end)
