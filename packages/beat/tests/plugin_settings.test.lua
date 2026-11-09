-- A plugin's own settings: the defaults its view starts from, the card the Plugins page draws,
-- and the message that changes one value and saves it. The app is built with the plugin supplied,
-- so nothing here reads the person's plugins folder.
local test = require("lde-test")
local fs = require("fs")
local json = require("json")
local wonderland = require("wonderland")
local paths = require("beat.paths")
local App = require("beat.app")
local beat = require("beat")
local messages = require("beat.message")
local settingsModel = require("beat.app.services.settings.model")

local configDirectory = os.tmpname() .. "-beat-plugin-settings"
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

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

--- What the card's view was given on its last draw, so the test can send the message it made.
---@type beat.PluginSettingsContext?
local seen

local function settingsPlugin()
	seen = nil
	return beat.plugin({
		name = "tester",
		version = "1.0.0",
		setup = function(handle)
			handle.settings({
				title = "Tester settings",
				defaults = { volume = 1, enabled = true },
				view = function(app, ctx)
					seen = ctx
					local theme = app.services.appearance.theme
					local on = ctx.values.enabled == true
					return div()
						:style(sty():row():w(ctx.width):h(40):gap(theme:px(10)):align("center"))
						:children(
							{
								text("Volume " .. tostring(ctx.values.volume))
									:style(theme:s():text(theme:type("sm")):fg(theme:color("text"))),
								div()
									:style(
										sty()
											:size(theme:px(90), theme:px(26)):radius(theme:radius("sm"))
											:bg(theme:color(on and "accent" or "elevated")):align("center"):justify("center")
									):onClick(ctx.set("enabled", not on))
									:children(
										text(on and "On" or "Off")
											:style(theme:s():text(theme:type("xs")):weight("semibold"):fg(theme:color("text")))
									)
							}
						)
				end,
				height = function() return 40 end
			})
		end
	})
end

test.it("fills in a plugin's defaults and keeps the same values table", function()
	App:init({ scan = false, plugins = { settingsPlugin() } })

	local values = App.services.settings:plugin("tester")
	test.equal(values.volume, 1)
	test.equal(values.enabled, true)
	test.truthy(values == App.services.settings:plugin("tester"), "reading again is the same table")
end)

test.it("saves one plugin setting and reads it back after a reload", function()
	App:init({ scan = false, plugins = { settingsPlugin() } })
	App:act(messages.pluginSetting("tester", "volume", 0.25))
	App.services.settings:flush()

	local saved = settingsModel.load()
	test.equal(saved.plugins.tester.volume, 0.25)

	App:init({ scan = false, plugins = { settingsPlugin() } })
	test.equal(App.services.settings:plugin("tester").volume, 0.25, "the next start sees the saved value")
end)

test.it("refuses a value JSON cannot hold", function()
	App:init({ scan = false, plugins = { settingsPlugin() } })

	App:act(messages.pluginSetting("tester", "volume", function() end))
	test.equal(App.services.settings:plugin("tester").volume, 1, "the refused value did not replace the default")

	App:act(messages.pluginSetting("tester", "volume", { nested = function() end }))
	test.equal(App.services.settings:plugin("tester").volume, 1)
end)

test.it("loads a malformed plugin entry as empty and keeps the rest", function()
	fs.write(
		paths.file("settings.json"),
		'{"plugins":{"good":{"volume":2},"bad":"not a table","alsoBad":{"x":null}}}'
	)

	local loaded = settingsModel.load()
	test.equal(loaded.plugins.good.volume, 2, "a valid entry is kept")
	test.deepEqual(loaded.plugins.bad, {}, "an entry that is not a table is empty")
	test.deepEqual(loaded.plugins.alsoBad, {}, "an entry with a value JSON cannot read back as a setting is empty")
	test.equal(loaded.plugins.removed, nil, "a plugin that is not loaded is not invented")

	fs.write(paths.file("settings.json"), json.encode({ plugins = "not a table" }))
	test.deepEqual(settingsModel.load().plugins, {}, "a malformed plugins field is empty")
end)

---@param screen wonderland.Headless
---@param value string
local function hasText(screen, value)
	local elements = require("wonderland.element")
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

---@param name string
local function shotPath(name)
	local folder = (os.getenv("TEMP") or os.getenv("TMP") or "/tmp") .. "/beat-ui"
	fs.mkdirAll(folder)
	return folder .. "/" .. name
end

test.skipIf(not canRender)("draws a plugin's settings card and its set message changes the value", function()
	App:init({ scan = false, plugins = { settingsPlugin() } })
	App.services.settings.values.root = "/beat-fixtures"
	App.page = { kind = "plugins" }

	local rendered = screen(1200, 760)
	rendered:draw()

	test.truthy(hasText(rendered, "Tester settings"), "the card's title is on the page")
	test.truthy(hasText(rendered, "Volume 1"), "the plugin's view is on the card")
	local ctx = seen --[[@as beat.PluginSettingsContext]]
	if ctx == nil then error("the card was not drawn") end
	test.equal(ctx.plugin, "tester")
	test.equal(ctx.values.volume, 1)

	local message = ctx.set("volume", 7)
	test.equal(message.type, "pluginSetting")
	test.equal(message.plugin, "tester")
	test.equal(message.key, "volume")
	test.equal(message.value, 7)
	App:act(message)
	test.equal(App.services.settings:plugin("tester").volume, 7, "the set message reached the settings service")

	rendered:draw()
	test.truthy(hasText(rendered, "Volume 7"), "the card redraws from the new value")

	local ok, err = rendered:save(shotPath("beat-plugins-1200x760.png"))
	test.truthy(ok, tostring(err))
	rendered:close()

	local phone = screen(520, 760)
	phone:draw()
	test.truthy(hasText(phone, "Tester settings"), "the card is drawn at phone width")
	local saved, saveErr = phone:save(shotPath("beat-plugins-520x760.png"))
	test.truthy(saved, tostring(saveErr))
	phone:close()
end)
