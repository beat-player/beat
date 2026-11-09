-- Minimize to tray: the setting that offers it, the window calls it makes, and the menu that
-- plays, shows and quits. The window is a table that records what it was asked to do, so no
-- backend is needed to see what the app does when it is minimized.
local test = require("lde-test")
local fs = require("fs")
local wonderland = require("wonderland")
local paths = require("beat.paths")
local App = require("beat.app")
local settingsModel = require("beat.app.services.settings.model")

local configDirectory = os.tmpname() .. "-beat-tray"
os.remove(configDirectory)
fs.mkdirAll(configDirectory)

local realDirectory = paths.directory
paths.directory = function() return configDirectory end

test.afterEach(function()
	if App.services ~= nil and App.services.playback ~= nil then App.services.playback.player:close() end
	App.window = nil
	App.instance = nil
	App.layoutPlugin = nil
	fs.delete(paths.file("settings.json"))
end)

test.afterAll(function()
	paths.directory = realDirectory
	fs.rmdir(configDirectory)
end)

--- What the fake window was asked to do.
---@class TestTrayCalls
---@field hide number?
---@field show number?
---@field setTray number?
---@field removeTray number?
---@field tray winit.Tray?
---@field trays winit.Tray[]

--- A window that records the optional calls the tray uses and reports its own visibility.
---@class TestTrayWindow
---@field width number
---@field height number
---@field visible boolean
---@field calls TestTrayCalls
---@field hide (fun(self: TestTrayWindow))?
---@field show (fun(self: TestTrayWindow))?
---@field setTray (fun(self: TestTrayWindow, tray: winit.Tray))?
---@field removeTray (fun(self: TestTrayWindow))?

---@param withTray boolean?
local function fakeWindow(withTray)
	---@type TestTrayWindow
	local window = {
		width = 1200,
		height = 720,
		visible = true,
		calls = { trays = {} }
	}
	if withTray ~= false then
		window.hide = function(self)
			self.visible = false
			self.calls.hide = (self.calls.hide or 0) + 1
		end
		window.show = function(self)
			self.visible = true
			self.calls.show = (self.calls.show or 0) + 1
		end
		---@param owner TestTrayWindow
		---@param tray winit.Tray
		window.setTray = function(owner, tray)
			owner.calls.setTray = (owner.calls.setTray or 0) + 1
			owner.calls.tray = tray
			owner.calls.trays[#owner.calls.trays + 1] = tray
		end
		window.removeTray = function(self) self.calls.removeTray = (self.calls.removeTray or 0) + 1 end
	end
	return window
end

--- The event carries a `winit.Window`, which a backend is; a test only needs the calls it records.
---@param window TestTrayWindow
local function asWindow(window)
	return window --[[@as winit.Window]]
end

---@return winit.EventManager
local function fakeHandler()
	return { exit = function() end }
end

--- The services the app asks to write before it goes, replaced so a test can see they were asked.
---@return { settings: boolean?, playback: boolean? }
---@return fun()
local function spyFlush()
	local flushed = {}
	local services = App.services
	local originals = {}
	for _, name in ipairs({ "settings", "playback" }) do
		local service = services[name]
		originals[name] = service.flush
		service.flush = function() flushed[name] = true end
	end
	return flushed, function()
		for name, flush in pairs(originals) do services[name].flush = flush end
	end
end

test.it("minimizing with the setting on hides the window, sets the icon and flushes", function()
	App:init({ scan = false })
	App.services.settings.values.minimizeToTray = true

	local window = fakeWindow()
	App.window = window
	local flushed, restore = spyFlush()

	App:event({ name = "minimize", window = asWindow(window) }, fakeHandler())
	restore()

	local tray = assert(window.calls.tray)
	local menu = assert(tray.menu)
	local toggle = menu[1] --[[@as { label: string }]]
	local separator = menu[4] --[[@as { separator: boolean? }]]
	local show = menu[5] --[[@as { id: string, default: boolean? }]]

	test.equal(window.calls.hide, 1, "the window left the screen")
	test.equal(window.calls.setTray, 1, "the icon was put in the notification area")
	test.equal(tray.tooltip, "beat", "nothing is loaded, so the tooltip is the app's name")
	test.equal(#menu, 6)
	test.equal(toggle.label, "Play")
	test.equal(separator.separator, true)
	test.equal(show.id, "show")
	test.equal(show.default, true)
	test.truthy(flushed.settings, "a setting still settling is written")
	test.truthy(flushed.playback, "the session's place is written")
end)

test.it("the settings switch turns the setting on and writes it", function()
	App:init({ scan = false })

	App:act({ type = "minimizeToTray", value = true })
	test.truthy(App.services.settings.values.minimizeToTray, "the change reached the settings service")

	App.services.settings:flush()
	test.truthy(settingsModel.load().minimizeToTray, "and settings.json holds it")
end)

test.it("minimizing with the setting off leaves the window alone", function()
	App:init({ scan = false })
	App.services.settings.values.minimizeToTray = false

	local window = fakeWindow()
	App.window = window
	local flushed, restore = spyFlush()

	App:event({ name = "minimize", window = asWindow(window) }, fakeHandler())
	restore()

	test.falsy(window.calls.hide)
	test.falsy(window.calls.setTray)
	test.falsy(flushed.settings)
	test.falsy(flushed.playback)
end)

test.it("a backend without a tray is never asked to hide the window", function()
	App:init({ scan = false })
	App.services.settings.values.minimizeToTray = true

	local window = fakeWindow(false)
	App.window = window

	App:event({ name = "minimize", window = asWindow(window) }, fakeHandler())

	test.falsy(window.calls.hide)
	test.falsy(window.calls.setTray)
end)

test.it("a click on the icon brings the window back and removes the icon", function()
	App:init({ scan = false })
	App.services.settings.values.minimizeToTray = true

	local window = fakeWindow()
	App.window = window
	App:event({ name = "minimize", window = asWindow(window) }, fakeHandler())

	App:event({ name = "trayClick", window = asWindow(window) }, fakeHandler())

	test.equal(window.calls.show, 1, "the window was brought back")
	test.equal(window.calls.removeTray, 1, "the icon was taken away")
	test.equal(window.visible, true)

	local trays = window.calls.setTray
	App:act({ type = "toast", text = "after the tray" })
	test.equal(window.calls.setTray, trays, "a window out of the tray is not updated again")
end)

test.it("the menu's show item does what the icon's click does", function()
	App:init({ scan = false })
	App.services.settings.values.minimizeToTray = true

	local window = fakeWindow()
	App.window = window
	App:event({ name = "minimize", window = asWindow(window) }, fakeHandler())

	App:event({ name = "trayMenu", id = "show", window = asWindow(window) }, fakeHandler())

	test.equal(window.calls.show, 1)
	test.equal(window.calls.removeTray, 1)
end)

test.it("the menu's playback items send the player's own messages", function()
	App:init({ scan = false })
	App.services.settings.values.minimizeToTray = true

	local window = fakeWindow()
	App.window = window
	App:event({ name = "minimize", window = asWindow(window) }, fakeHandler())

	local kinds = {}
	App.messages:connect(function(message) kinds[#kinds + 1] = message.type end)
	App:event({ name = "trayMenu", id = "next", window = asWindow(window) }, fakeHandler())
	App:event({ name = "trayMenu", id = "previous", window = asWindow(window) }, fakeHandler())
	App:event({ name = "trayMenu", id = "toggle", window = asWindow(window) }, fakeHandler())
	table.remove(App.messages.listeners)

	test.equal(table.concat(kinds, ","), "next,previous,togglePlay")
end)

test.it("the menu names the play state and the tooltip follows the track in the tray", function()
	App:init({ scan = false })
	App.services.settings.values.minimizeToTray = true

	local window = fakeWindow()
	App.window = window

	local playback = App.services.playback
	local playing = true
	local fake = {
		isPlaying = function() return playing end,
		pause = function() playing = false end,
		position = function() return 0 end,
		close = function() end
	}
	---@cast fake treble.Player
	playback.player.player = fake

	App:event({ name = "minimize", window = asWindow(window) }, fakeHandler())
	local tray = assert(window.calls.tray)
	local toggle = assert(tray.menu)[1] --[[@as { label: string }]]
	test.equal(toggle.label, "Pause", "a playing track offers Pause")

	App:act({ type = "pause" })
	tray = assert(window.calls.tray)
	toggle = assert(tray.menu)[1] --[[@as { label: string }]]
	test.equal(toggle.label, "Play", "a paused track offers Play")

	local track = { id = 1, title = "Nightfall", artist = "Aria", albumId = 1, artistId = 1 }
	---@cast track beat.Track
	local queue = { current = function() return track end }
	---@cast queue beat.Queue
	playback.player.queue = queue
	local started = assert(playback.player.onTrackStarted)
	started(track, 0)

	tray = assert(window.calls.tray)
	toggle = assert(tray.menu)[1] --[[@as { label: string }]]
	test.equal(tray.tooltip, "Nightfall – Aria", "the tooltip names the new track")
	test.equal(toggle.label, "Play", "and the menu is still current")
end)

test.it("the menu's Quit flushes what close flushes and exits the loop", function()
	App:init({ scan = false })
	App.services.settings.values.minimizeToTray = true

	local window = fakeWindow()
	App.window = window
	local flushed, restore = spyFlush()
	local exited = 0
	---@type winit.EventManager
	local handler = {
		exit = function() exited += 1 end
	}

	App:event({ name = "trayMenu", id = "quit", window = asWindow(window) }, handler)
	restore()

	test.truthy(flushed.settings, "the settings were written")
	test.truthy(flushed.playback, "the session was written")
	test.equal(exited, 1, "the loop was asked to stop")
end)

-- The settings screen offers the switch only where the window can hold an icon. The draws below
-- are also what puts the row in front of a person: the PNGs are written for a look at the layout.
local canRender = true
do
	local ok = pcall(function()
		wonderland.headless.new(function() return wonderland.div() end, { width = 8, height = 8 }):close()
	end)
	canRender = ok
end

---@param width number
---@param height number
local function screen(width, height)
	return wonderland.headless.new(function(window, assets)
		App.window = window
		App.assets = assets
		App.services.covers:use(assets)
		return require("beat.app.shell").view(App, window)
	end, { width = width, height = height })
end

---@param value string
local function hasText(rendered, value)
	local elements = require("wonderland.element")
	local layout = rendered:getPlugin("layout")
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

test.skipIf(not canRender)("draws the tray setting at desktop and phone widths", function()
	App:init({ scan = false })
	App.services.settings.values.root = "/beat-fixtures"
	App.page = { kind = "settings" }

	local desktop = screen(1200, 760)
	desktop.window.setTray = function() end
	App.services.scroll:reset("settings")
	desktop:draw()
	test.truthy(hasText(desktop, "Minimize to tray"), "the row is on the page where it can work")
	local desktopOk, desktopErr = desktop:save(shotPath("beat-tray-setting-1200x760.png"))
	test.truthy(desktopOk, tostring(desktopErr))
	desktop:close()

	local phone = screen(520, 760)
	phone.window.setTray = function() end
	App.services.scroll:reset("settings")
	phone:draw()
	test.truthy(hasText(phone, "Minimize to tray"), "the row fits the phone page")
	local phoneOk, phoneErr = phone:save(shotPath("beat-tray-setting-520x760.png"))
	test.truthy(phoneOk, tostring(phoneErr))

	App:act({ type = "scroll", key = "settings", to = 380 })
	phone:draw()
	test.truthy(hasText(phone, "Minimize to tray"), "the row is there once the page is scrolled to it")
	local scrolledOk, scrolledErr = phone:save(shotPath("beat-tray-setting-520x760-scrolled.png"))
	test.truthy(scrolledOk, tostring(scrolledErr))
	phone:close()

	local plain = screen(1200, 760)
	App.services.scroll:reset("settings")
	plain:draw()
	test.falsy(hasText(plain, "Minimize to tray"), "a backend without a tray does not offer the switch")
	local plainOk, plainErr = plain:save(shotPath("beat-tray-setting-none-1200x760.png"))
	test.truthy(plainOk, tostring(plainErr))
	plain:close()
end)

--- A claim on the config directory that reports one launch asking for the window.
---@return beat.Instance
local function askedOnce()
	local asked = true
	return {
		poll = function()
			local was = asked
			asked = false
			return was
		end,
		release = function() end
	}
end

test.it("another launch brings the window out of the tray", function()
	App:init({ scan = false })
	App.services.settings.values.minimizeToTray = true
	local window = fakeWindow()
	App.window = window
	local _, restore = spyFlush()
	App:event({ name = "minimize", window = asWindow(window) }, fakeHandler())
	restore()

	App.instance = askedOnce()
	App:tick(0, window --[[@as wonderland.RenderWindow]])
	App:tick(0.5, window --[[@as wonderland.RenderWindow]])

	test.equal(window.calls.show, 1, "the window came back once, for the one launch")
	test.equal(window.calls.removeTray, 1, "and the icon went")
end)

test.it("another launch brings a minimized window up from the taskbar", function()
	App:init({ scan = false })
	local window = fakeWindow()
	App.window = window

	App.instance = askedOnce()
	App:tick(0, window --[[@as wonderland.RenderWindow]])

	test.equal(window.calls.show, 1)
	test.equal(window.calls.removeTray, nil, "there was no icon to take away")
end)
