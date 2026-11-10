-- The task list in the app: the top bar's button appears only while there are tasks, the panel
-- draws a running task with progress, one with none, and a failure, and what is pressed in the
-- panel reaches the services without closing it. The app is headless here, so the pictures are
-- the test.
local test = require("lde-test")
local fs = require("fs")
local wonderland = require("wonderland")
local paths = require("beat.paths")
local App = require("beat.app")

local configDirectory = os.tmpname() .. "-beat-tasks-ui"
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

local elements = require("wonderland.element")
local metrics = require("beat.app.components.helpers.metrics")

---@param width number
---@param height number
---@param onMessage fun(message: any)?
local function screen(width, height, onMessage)
	return wonderland.headless.new(function(window, assets)
		App.window = window
		App.assets = assets
		App.services.covers:use(assets)
		return require("beat.app.shell").view(App, window)
	end, { width = width, height = height, onMessage = onMessage })
end

--- Where the task button sits in the top bar: left of settings, which is the last control.
---@param app beat.App
---@param width number
---@return number x
---@return number y
local function taskButtonAt(app, width)
	local theme = app.services.appearance.theme
	local mobile = metrics.mobile(app, width)
	local pad = metrics.pad(app, width)
	local icon = theme:px(mobile and 40 or 32)
	local gap = theme:px(10)
	return width - pad - icon - gap - icon / 2, metrics.topbarHeight(app, width) / 2
end

---@param screen wonderland.Headless
---@param value string
local function hasText(screen, value)
	local layout = screen:getPlugin("layout")
	local ctx
	for _, context in pairs(layout.contexts) do ctx = context end
	if ctx == nil then return false end

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

---@param name string
local function shotPath(name)
	local folder = (os.getenv("TEMP") or os.getenv("TMP") or "/tmp") .. "/beat-ui"
	fs.mkdirAll(folder)
	return folder .. "/" .. name
end

test.skipIf(not canRender)("shows the task button only while there are tasks", function()
	App:init({ scan = false })
	App.services.settings.values.root = "/beat-fixtures"
	App.page = { kind = "settings" }

	local previousLayout = App.layoutPlugin
	local rendered
	rendered = screen(1200, 760, function(message)
		App:act(message)
		rendered:draw()
	end)
	App.layoutPlugin = assert(rendered:getPlugin("layout"))
	rendered:draw()
	local x, y = taskButtonAt(App, 1200)

	rendered:click(x, y)
	test.equal(App:overlay("tasks"), nil, "no tasks means no task button")

	local task = App.services.tasks:start({ title = "Syncing" })
	rendered:draw()
	rendered:click(x, y)
	test.truthy(App:overlay("tasks") ~= nil, "a running task gives the top bar its button")
	App:close("tasks")

	task:finish()
	local endedAt = assert(task.endedAt)
	App.services.tasks:step(endedAt + 6)
	rendered:draw()
	rendered:click(x, y)
	test.equal(App:overlay("tasks"), nil, "the button goes with the last task")

	rendered:close()
	App.layoutPlugin = previousLayout
end)

test.skipIf(not canRender)("draws the task panel at desktop and phone widths", function()
	App:init({ scan = false })
	App.services.settings.values.root = "/beat-fixtures"
	App.page = { kind = "settings" }

	local tasks = App.services.tasks
	tasks:start({
		title = "Downloading album",
		detail = "2 of 5 tracks",
		progress = 0.4,
		cancel = { type = "download:cancel", custom = true }
	})
	tasks:start({ title = "Syncing library", detail = "Waiting for the folder" })
	tasks:start({ title = "Uploading cover", detail = "Album art" }):fail("Connection refused")
	App:open("tasks")

	local desktop = screen(1200, 760)
	desktop:draw()
	test.truthy(hasText(desktop, "Downloading album"))
	test.truthy(hasText(desktop, "Syncing library"))
	test.truthy(hasText(desktop, "Connection refused"))
	local ok, err = desktop:save(shotPath("beat-tasks-1200x760.png"))
	test.truthy(ok, tostring(err))
	desktop:close()

	App.services.scroll:reset("tasks")
	local phone = screen(520, 760)
	phone:draw()
	test.truthy(hasText(phone, "Downloading album"))
	local saved, saveErr = phone:save(shotPath("beat-tasks-520x760.png"))
	test.truthy(saved, tostring(saveErr))
	phone:close()
end)

-- The panel takes its own scrolling and a cancel for itself, so a light popover does not close on
-- them, and has to pass both on: a cancel that stops at the panel leaves the task running.
test.it("passes the list's scroll and a cancel from the open panel on to their services", function()
	App:init({ scan = false })
	local task = App.services.tasks:start({ title = "Downloading album", cancel = { type = "toast", text = "Stopping" } })
	App:open("tasks")

	App:act({ type = "scroll", key = "tasks", to = 30, max = 100 })
	test.equal(App.services.scroll:offset("tasks"), 30, "the scroll service took the list's scroll")
	test.truthy(App:overlay("tasks") ~= nil, "and the panel stayed open for it")

	App:act({ type = "taskCancel", id = task.id })
	test.equal(task.state, "cancelling", "the tasks service took the cancel")
end)
