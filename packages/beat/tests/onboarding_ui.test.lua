-- The first launch: the welcome card, what its buttons send, and the folder browser the second step
-- draws. The app is headless here, so the click is the test.
local test = require("lde-test")
local fs = require("fs")
local wonderland = require("wonderland")
local elements = require("wonderland.element")
local paths = require("beat.paths")
local App = require("beat.app")

local configDirectory = os.tmpname() .. "-beat-onboarding-ui"
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

--- Where a piece of text is on the screen, in window coordinates. The layout keeps nodes relative
--- to the box above them, so the walk adds each one up.
---@param screen wonderland.Headless
---@param value string
---@return { x: number, y: number }?
local function textCentre(screen, value)
	local layout = screen:getPlugin("layout")
	local ctx
	for _, context in pairs(layout.contexts) do ctx = context end
	if ctx == nil then return nil end

	local found
	local function walk(index, parentX, parentY)
		if found ~= nil then return end
		local node = ctx.screen:node(index)
		local x, y = parentX + node.x, parentY + node.y
		local element = elements.pointers[node.element]
		if element ~= nil and elements.textOf(element) == value then
			found = { x = x + node.width / 2, y = y + node.height / 2 }
			return
		end
		for child = 0, node.childCount - 1 do
			local nextIndex = ctx.screen.childIndices[node.firstChild + child - 1]
			if nextIndex ~= nil then walk(nextIndex, x, y) end
		end
	end
	walk(ctx.root, 0, 0)
	return found
end

--- A launch with no root, drawn, and the messages its clicks came to.
---@return wonderland.Headless screen
---@return { type: string, path: string? }[] messages
local function firstLaunch()
	App:init({ scan = false })
	local screen
	---@type { type: string, path: string? }[]
	local messages = {}
	screen = wonderland.headless.new(function(window, assets)
		App.window = window
		App.assets = assets
		App.services.covers:use(assets)
		return require("beat.app.shell").view(App, window)
	end, {
		width = 1200,
		height = 720,
		onMessage = function(message) messages[#messages + 1] = message end
	})
	App.layoutPlugin = assert(screen:getPlugin("layout"))
	screen:draw()
	return screen, messages
end

---@param messages { type: string, path: string? }[]
local function last(messages)
	return messages[#messages]
end

test.skipIf(not canRender)("the welcome step's primary action asks the system for a folder", function()
	local screen, messages = firstLaunch()
	test.truthy(textCentre(screen, "Welcome to beat") ~= nil, "the first launch greets")

	local button = assert(textCentre(screen, "Choose music folder"), "the welcome offers the picker")
	screen:click(button.x, button.y)
	test.equal(last(messages).type, "chooseFolder", "and the click asks for the system folder dialog")

	local browse = assert(textCentre(screen, "Browse folders"), "the welcome also offers the in-app browser")
	screen:click(browse.x, browse.y)
	test.equal(last(messages).type, "onboardingBrowse", "which asks the page for the folder step")

	screen:close()
end)

test.skipIf(not canRender)("the folder step lists folders and its own actions", function()
	local screen, messages = firstLaunch()
	App:act({ type = "onboardingBrowse" })
	screen:draw()

	test.truthy(textCentre(screen, "Welcome to beat") == nil, "the welcome is gone")
	test.truthy(textCentre(screen, "Choose your music folder") ~= nil, "the browser is showing")
	local use = assert(textCentre(screen, "Use this folder"), "the folder can be used")
	screen:click(use.x, use.y)
	local message = last(messages)
	test.equal(message.type, "folderSelect", "the click selects the folder showing")
	test.equal(message.path, App.page.state.path, "with the path the browser read")

	local back = assert(textCentre(screen, "Back"), "and it can go back to the welcome")
	screen:click(back.x, back.y)
	test.equal(last(messages).type, "onboardingWelcome", "Back asks for the welcome step")
	App:act(last(messages))
	screen:draw()
	test.equal(App.page.state.step, "welcome", "Back returns to the welcome step")
	test.truthy(textCentre(screen, "Welcome to beat") ~= nil)

	screen:close()
end)
