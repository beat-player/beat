-- What the phone's keyboard does to a field, without a phone. The Java editor sends byte ranges
-- of the field's value and the text that replaced them; these drive that protocol through the
-- service against a real wonderland field, so what a glide, a correction and a backspace leave
-- on screen is what is read back.
local test = require("lde-test")
local wonderland = require("wonderland")
local TextInput = require("beat.app.services.system.text_input")

local canRender = true
do
	local ok = pcall(function()
		wonderland.headless.new(function() return wonderland.div() end, { width = 8, height = 8 }):close()
	end)
	canRender = ok
end

--- A keyboard queue, standing in for the Java editor's: the commands it would have sent.
---@class beat.FakeKeyboard
---@field entries string[]
---@field synced { text: string, cursor: number }?
---@field shown boolean
---@field hidden boolean
---@field action number?
local Fake = {}
Fake.__index = Fake

---@param entries string[]
---@return beat.FakeKeyboard
function Fake.new(entries)
	return setmetatable({ entries = entries, synced = nil, shown = false, hidden = false, action = nil }, Fake)
end

function Fake:poll()
	return table.remove(self.entries, 1)
end

function Fake:sync(text, cursor)
	self.synced = { text = text, cursor = cursor }
end

function Fake:show(text, cursor, action)
	self.shown, self.synced, self.action = true, { text = text, cursor = cursor }, action
end

function Fake:hide()
	self.hidden, self.shown = true, false
end

--- A screen with beat's search field, the layout that owns it, and a service whose keyboard is
--- the queue given. `heard` keeps what the field's oninput was told; `messages` what the service
--- emitted, which is how the app hears the edit.
local function harness(entries)
	local heard = { last = "", values = {} }
	local screen = wonderland.headless.new(function()
		return wonderland.div():input({
			name = "search",
			value = "",
			oninput = function(value)
				heard.last = value
				heard.values[#heard.values + 1] = value
				return { type = "search", value = value }
			end,
			onsubmit = function()
				return { type = "submit" }
			end
		})
	end, { width = 200, height = 60 })
	local layout = screen.plugins.layout
	layout:setFocus(screen.window, "search")

	local messages = {}
	local keyboard = Fake.new(entries)
	local service = TextInput.new({
		app = { layoutPlugin = layout },
		window = function() return screen.window end,
		emit = function(message) messages[#messages + 1] = message end
	})
	service.bridge = keyboard

	return screen, layout, keyboard, service, heard, messages
end

test.it("puts a committed word in the field", function()
	if not canRender then return end

	local screen, layout, _, service, heard, messages = harness({ "r0,0,5:hello" })
	service:drain()

	local value, cursor = layout:getInput(screen.window)
	test.equal(value, "hello", "the field holds the committed word")
	test.equal(cursor, 5, "the caret is after it")
	test.equal(heard.last, "hello", "the field's oninput heard it")
	test.equal(messages[1] and messages[1].type, "search", "the app hears the field's own message")
	screen:close()
end)

test.it("shows a composing word as it grows and keeps the committed one", function()
	if not canRender then return end

	local screen, layout, keyboard, service = harness({})
	local window = screen.window

	keyboard.entries[#keyboard.entries + 1] = "r0,0,3:wor"
	service:drain()
	test.equal((layout:getInput(window)), "wor", "the first composing update is shown")

	keyboard.entries[#keyboard.entries + 1] = "r0,3,4:worl"
	service:drain()
	test.equal((layout:getInput(window)), "worl", "replacing the composing region does not double it")

	keyboard.entries[#keyboard.entries + 1] = "r0,4,5:world"
	keyboard.entries[#keyboard.entries + 1] = "r0,5,6:world "
	service:drain()

	local value, cursor = layout:getInput(window)
	test.equal(value, "world ", "the committed word replaces the composing one")
	test.equal(cursor, 6, "the caret is after the committed word")
	screen:close()
end)

test.it("deletes the characters a correction asked for", function()
	if not canRender then return end

	local screen, layout, _, service = harness({ "r0,0,5:hello", "r3,5,3:" })
	service:drain()

	local value, cursor = layout:getInput(screen.window)
	test.equal(value, "hel", "two characters before the caret are gone")
	test.equal(cursor, 3, "the caret is where they were")
	screen:close()
end)

test.it("takes a backspace the keyboard sent as a key", function()
	if not canRender then return end

	local screen, layout, _, service = harness({ "r0,0,5:hello", "kbackspace" })
	service:drain()

	local value, cursor = layout:getInput(screen.window)
	test.equal(value, "hell", "the character before the caret is gone")
	test.equal(cursor, 4, "the caret moved back with it")
	screen:close()
end)

test.it("takes a whole character for a byte range over more than one byte", function()
	if not canRender then return end

	-- "café" is five bytes: the last character is two, as a glide in another language may be.
	local screen, layout, _, service = harness({ "r0,0,5:café", "kbackspace" })
	service:drain()

	test.equal((layout:getInput(screen.window)), "caf", "the accented character went whole")
	screen:close()
end)

test.it("moves the caret where the keyboard put it", function()
	if not canRender then return end

	local screen, layout, _, service = harness({ "r0,0,5:hello", "p2" })
	service:drain()

	local value, cursor = layout:getInput(screen.window)
	test.equal(value, "hello", "the text is untouched")
	test.equal(cursor, 2, "the caret is at the byte the keyboard named")
	screen:close()
end)

test.it("sends the field's value with the action key", function()
	if not canRender then return end

	local screen, layout, _, service, _, messages = harness({ "r0,0,5:hello", "a3" })
	service:drain()

	test.equal(messages[#messages] and messages[#messages].type, "submit", "the action is the field's return")
	screen:close()
end)

test.it("ignores a command it does not know", function()
	if not canRender then return end

	local screen, layout, _, service = harness({})
	test.falsy(service:apply("nonsense", layout, screen.window))
	test.equal((layout:getInput(screen.window)), "", "the field is unchanged")
	screen:close()
end)

test.it("shows the keyboard over a search field and mirrors what it holds", function()
	if not canRender then return end

	local screen, layout, keyboard, service = harness({})
	local layoutPlugin = screen.plugins.layout

	-- The focus a field gets is what a step reads: the keyboard is up, and the mirror is told the
	-- value and caret before the first edit.
	service.shown = false
	service.bridge = keyboard
	layoutPlugin:setFocus(screen.window, "search")
	service:show("", 0, layoutPlugin:getFocusedId(screen.window))

	test.truthy(keyboard.shown, "the keyboard was asked for")
	test.equal(keyboard.synced.text, "", "the mirror starts at the field's value")
	test.equal(keyboard.action, 3, "a search field gets the search action key")
	screen:close()
end)

test.it("takes the keyboard over while a field is focused and gives it back after", function()
	if not canRender then return end

	local platform = require("beat.platform")
	local wasAndroid = platform.android
	platform.android = true

	local screen, layout, keyboard, service = harness({})
	screen.window.visible = true

	---@type fun(enabled: boolean): boolean?
	local onKeyboard
	screen.window.setTextInputHandler = function(_, handler)
		onKeyboard = handler
	end

	test.truthy(service:start(screen.window), "the fake editor is enough to start")
	test.equal(onKeyboard ~= nil, true, "the window's own keyboard is replaced")

	local _, busy = service:step(0)
	test.truthy(keyboard.shown, "a focused field brings the keyboard up")
	test.truthy(busy, "a focused field asks to be polled every frame")

	layout:setFocus(screen.window, nil)
	service:step(0)
	test.truthy(keyboard.hidden, "losing the field lets the keyboard go")

	platform.android = wasAndroid
	screen:close()
end)

test.it("slows the keyboard poll when the field is not being typed into", function()
	if not canRender then return end

	local platform = require("beat.platform")
	local wasAndroid = platform.android
	platform.android = true

	local screen, _, _, service, _, _ = harness({ "r0,0,5:hello" })
	screen.window.visible = true
	local now = wonderland.time.now()

	local _, shownBusy = service:step(now)
	test.less(shownBusy, 0.05, "a field that just took the keyboard is read fast")

	local _, typedBusy = service:step(now + 0.1)
	test.less(typedBusy, 0.05, "a word arriving keeps the fast pace")

	local _, quietBusy = service:step(now + 2)
	test.equal(quietBusy, 0.25, "a field that has been still is read four times a second")

	platform.android = wasAndroid
	screen:close()
end)
