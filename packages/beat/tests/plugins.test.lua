-- What a plugin can add to beat from outside, and what happens when it cannot: menu entries,
-- message hooks, overlays, versions that do not match, names that are not its own, and a mistake
-- that must not take the app with it. The app is built headlessly, so nothing here needs a window.
local test = require("lde-test")
local fs = require("fs")
local wonderland = require("wonderland")
local path = require("path")
local json = require("json")
local paths = require("beat.paths")
local Library = require("beat.music.library")
local App = require("beat.app")
local beat = require("beat")
local Picker = require("beat.app.services.scan.picker")

local realPickStart, realPickPoll = Picker.start, Picker.poll

-- Settings, tags and the library cache are written under `paths.directory`; a test must not put
-- its fixtures where the person's real library cache lives.
local configDirectory = os.tmpname() .. "-beat-plugins"
os.remove(configDirectory)
fs.mkdirAll(configDirectory)

local realDirectory = paths.directory
paths.directory = function() return configDirectory end

test.afterAll(function()
	paths.directory = realDirectory
	fs.rmdir(configDirectory)
end)

test.afterEach(function()
	Picker.start, Picker.poll = realPickStart, realPickPoll
	if App.services ~= nil and App.services.playback ~= nil then App.services.playback.player:close() end
	-- The folder and the settings file are this test's fixtures, not the person's. A switch test
	-- reads the file back, so it must not leak into the next test or into a real launch.
	local folder = paths.file("plugins")
	if fs.isdir(folder) then fs.rmdir(folder) end
	fs.delete(paths.file("settings.json"))
end)

local function fixture()
	local library = Library.new("/beat-plugin-fixtures")
	local dir = "/beat-plugin-fixtures/Artist/Album"
	for at = 1, 2 do
		library:add({
			format = "FLAC",
			sampleRate = 44100,
			channels = 2,
			duration = 180,
			hasPicture = false,
			tags = {
				title = "Track " .. at,
				artist = "Artist",
				album = "Album",
				albumArtist = "Artist",
				track = at,
			},
		}, {
			path = dir .. "/" .. at .. ".flac",
			dir = dir,
			name = at .. ".flac",
			ext = "flac",
		}, nil)
	end
	library:finish()
	return library
end

---@param title string
---@return table?
local function action(actions, title)
	for _, entry in ipairs(actions) do
		if entry.title == title then return entry end
	end
	return nil
end

---@param text string
---@return boolean
local function reported(text)
	for _, toast in ipairs(App.services.toasts.list) do
		if toast.text:find(text, 1, true) ~= nil then return true end
	end
	return false
end

---@param ctx beat.MenuContext
---@return beat.Message
local function openInRateYourMusic(ctx)
	local album = assert(ctx.album)
	return ctx.message.openURL("https://rateyourmusic.com/album/" .. album.id)
end

---@param name string
---@return beat.PluginStatus?
local function entry(name)
	for _, value in ipairs(App.pluginStates or {}) do
		if value.name == name then return value end
	end
	return nil
end

--- Writes one plugin bundle into the config directory's plugins folder and returns its path.
---@param name string
---@param body string
---@return string
local function writePlugin(name, body)
	local folder = paths.file("plugins")
	fs.mkdirAll(folder)
	local file = path.join(folder, name)
	test.truthy(fs.write(file, body), "the plugin fixture was written")
	return file
end

-- A file in the shape `lde bundle` writes: a private module and a bundled copy of `json` in
-- `package.preload`, then the entry module, whose return value is the plugin table. The copy of
-- json must not replace the host's.
local PROBE = [[
package.preload["probe.private"] = function()
	return { answer = 42, host = require("json") }
end
package.preload["json"] = function()
	return { tampered = true }
end
package.preload["probe"] = function()
	return {
		name = "probe",
		version = "2.3.4",
		setup = function(beat)
			local private = require("probe.private")
			beat.action({
				menu = "album",
				title = "Private answer",
				message = { type = "toast", text = "answer " .. private.answer },
			})
		end,
	}
end
return package.preload["probe"](...)
]]
test.it("adds an album action whose message reaches the service it names", function()
	local plugin = beat.plugin({
		name = "rym",
		version = "1.0.0",
		setup = function(handle)
			handle.action({
				menu = "album",
				title = "Open in Rate Your Music",
				message = openInRateYourMusic,
			})
		end,
	})
	App:init({ scan = false, plugins = { plugin } })
	App.services.library.current = fixture()
	local album = App.services.library.current.albums[1]

	local actions = App.registry:actions("album", { album = album })
	local entry = action(actions, "Open in Rate Your Music")
	test.truthy(entry ~= nil, "the plugin's entry is in the album menu")
	test.equal(entry.message.type, "openURL")

	local opened
	App.services.system.open = function(_, url)
		opened = url
		return true
	end

	App:act({ type = "open", overlay = "menu", menu = "album", id = album.id, x = 30, y = 30})
	test.truthy(App:overlay("menu") ~= nil, "the album menu opens")
	App:act(entry.message)
	test.equal(opened, "https://rateyourmusic.com/album/" .. album.id, "the system service got the URL")
	test.equal(App:overlay("menu"), nil, "the menu closes as the message passes")
end)

test.it("lets an interceptor cancel a message and send another one", function()
	local replayed = 0
	---@param message { type: string, id: number, shuffle: boolean? }
	---@param app beat.App
	---@param proceed fun(message: beat.Message?)
	local function shuffleFirst(message, app, proceed)
		if message.shuffle ~= true then
			replayed = replayed + 1
			app:act({ type = "playAlbum", id = message.id, shuffle = true })
			return
		end
		proceed(message)
	end
	local plugin = beat.plugin({
		name = "shuffler",
		version = "1.0.0",
		setup = function(handle)
			handle.intercept("playAlbum", shuffleFirst)
		end,
	})
	App:init({ scan = false, plugins = { plugin } })
	App.services.library.current = fixture()
	local album = App.services.library.current.albums[1]

	local calls = {}
	App.services.playback.playAlbum = function(_, id, shuffle)
		calls[#calls + 1] = { id = id, shuffle = shuffle}
	end

	App:act({ type = "playAlbum", id = album.id })
	test.equal(replayed, 1, "the interceptor saw the original")
	test.equal(#calls, 1, "the original was cancelled and only the replay arrived")
	test.equal(calls[1].id, album.id)
	test.equal(calls[1].shuffle, true, "the replay is the shuffled one the interceptor made")
end)

test.it("tells listeners about a message after it has been delivered", function()
	local heard = {}
	---@param message { type: string, track: { title: string } }
	---@param app beat.App
	local function noteStart(message, app)
		heard[#heard + 1] = message.track.title .. "@" .. tostring(app ~= nil)
	end
	local plugin = beat.plugin({
		name = "listener",
		version = "1.0.0",
		setup = function(handle)
			handle.on("trackStarted", noteStart)
		end,
	})
	App:init({ scan = false, plugins = { plugin } })

	App:act({ type = "trackStarted", track = { title = "A Track" }, position = 0})
	test.equal(#heard, 1)
	test.equal(heard[1], "A Track@true", "the listener saw the delivered message and the app")
end)

---@param _ beat.App
---@param params beat.OverlayParams
---@return beat.OverlayState
local function panelCard(_, params) return { value = params.value} end

test.it("opens an overlay a plugin named after itself", function()
	local plugin = beat.plugin({
		name = "panel",
		version = "1.0.0",
		setup = function(handle)
			handle.overlay("panel:card", { new = panelCard })
		end,
	})
	App:init({ scan = false, plugins = { plugin } })

	App:act({ type = "open", overlay = "panel:card", value = 7})
	local overlay = App:overlay("panel:card")
	test.truthy(overlay ~= nil, "the namespaced overlay opens")
	test.equal(overlay.state.value, 7, "it was given the message that opened it")
end)

test.it("leaves out a plugin whose version requirement does not match", function()
	local baseRan, needsRan = false, false
	---@type beat.PluginModule
	local base = {
		name = "base",
		version = "1.0.0",
		setup = function() baseRan = true end,
	}
	---@type beat.PluginModule
	local needs = {
		name = "needs",
		version = "1.0.0",
		requires = { base = "^2.0.0" },
		setup = function() needsRan = true end,
	}
	App:init({ scan = false, plugins = { base, needs } })

	test.truthy(baseRan, "the plugin it wanted was loaded")
	test.falsy(needsRan, "the plugin that wanted the wrong version never set up")
	test.truthy(reported("needs plugin base ^2.0.0"), "and the mismatch was reported")
end)

test.it("refuses a page that is not named after its plugin", function()
	local plugin = beat.plugin({
		name = "sloppy",
		version = "1.0.0",
		setup = function(handle)
			handle.action({
				menu = "album",
				title = "Should be rolled back",
				message = { type = "toast", text = "never" },
			})
			handle.page("home", { view = function() return wonderland.div() end })
		end,
	})
	App:init({ scan = false, plugins = { plugin } })

	test.equal(action(App.registry:actions("album", { album = { id = 1 } }), "Should be rolled back"), nil,
	"the registrations made before the bad page were taken back")
	test.equal(App.registry:page("home"), require("beat.app.pages.home"), "the built-in page is still there")
	test.truthy(reported("must be named"), "the reason was reported")
end)

test.it("adds a page a plugin named after itself", function()
	local plugin = beat.plugin({
		name = "panel",
		version = "1.0.0",
		setup = function(handle)
			handle.page("panel:page", {
				new = function() return { hello = true } end,
				view = function() return wonderland.div() end,
			})
		end,
	})
	App:init({ scan = false, plugins = { plugin } })

	App:act({ type = "navigate", page = { kind = "panel:page" }})
	test.equal(App.page.kind, "panel:page", "the namespaced page is navigated to")
	test.equal(App:currentPage().state.hello, true, "it was given the state its surface starts with")
end)

test.it("puts a plugin's destination in the sidebar model and reaches its page", function()
	local plugin = {
		name = "bandcamp",
		version = "1.0.0",
		setup = function(beat)
			beat.page("bandcamp:search", {
				new = function() return { hello = true } end,
				view = function() return nil end,
			})
			beat.nav({
				id = "bandcamp:search",
				title = "Bandcamp",
				icon = "search",
				page = { kind = "bandcamp:search"},
			})
		end,
	}
	App:init({ scan = false, plugins = { plugin } })

	local entries = App.registry:nav()
	test.equal(#entries, 1)
	test.equal(entries[1].id, "bandcamp:search")
	test.equal(entries[1].title, "Bandcamp")
	test.equal(entries[1].page.kind, "bandcamp:search")

	App:act({ type = "navigate", page = entries[1].page})
	test.equal(App.page.kind, "bandcamp:search", "the sidebar entry's page is reachable")
	test.equal(App:currentPage().state.hello, true)
end)

test.it("refuses a nav entry that is not named after its plugin, and rolls back the rest", function()
	local plugin = {
		name = "sloppy",
		version = "1.0.0",
		setup = function(beat)
			beat.action({
				menu = "album",
				title = "Should be rolled back",
				message = { type = "toast", text = "never" },
			})
			beat.nav({
				id = "search",
				title = "Sloppy",
				icon = "search",
				page = { kind = "home"},
			})
		end,
	}
	App:init({ scan = false, plugins = { plugin } })

	test.equal(#App.registry:nav(), 0, "the un-namespaced entry is not in the sidebar")
	test.equal(action(App.registry:actions("album", { album = { id = 1 } }), "Should be rolled back"), nil,
		"the registrations made before the bad nav entry were taken back")
	test.truthy(reported("must be named"), "the reason was reported")
end)

test.it("asks the folder dialog for a plugin and answers with the path or nil", function()
	local replies = {}
	local plugin = {
		name = "bandcamp",
		version = "1.0.0",
		setup = function(beat)
			beat.on("bandcamp:folder", function(message)
				replies[#replies + 1] = { path = message.path }
			end)
		end,
	}
	App:init({ scan = false, plugins = { plugin } })

	local started
	Picker.start = function(_, opts)
		started = opts
		return { file = "stand-in", platform = "test"}
	end
	Picker.poll = function() return "/music/Downloaded" end

	App:act({ type = "pickFolder", reply = "bandcamp:folder"})
	test.equal(started.title, "Choose a folder")
	local window = { width = 1200, height = 720, shouldRedraw = false}
	App:tick(10, window)
	test.equal(replies[1].path, "/music/Downloaded", "the chosen folder came back as the reply")

	Picker.poll = function() return nil, "cancelled" end
	App:act({ type = "pickFolder", reply = "bandcamp:folder"})
	App:tick(11, window)
	test.equal(#replies, 2)
	test.equal(replies[2].path, nil, "a cancelled dialog answers with no path")
end)

test.it("builds a service a plugin added and lets it answer its own messages", function()
	local answered = 0
	---@param _ beat.ServiceInstance
	---@param message beat.Message
	local function onPing(_, message) answered = answered + message.by end
	---@type beat.Service
	local service = {
		needs = {},
		handles = { "counter:ping" },
		new = function() return {} end,
		update = onPing,
	}

	local plugin = beat.plugin({
		name = "counter",
		version = "1.0.0",
		setup = function(handle) handle.service("counter:service", service) end,
	})
	App:init({ scan = false, plugins = { plugin } })

	App:act({ type = "counter:ping", by = 2 })
	test.equal(answered, 2, "the service was built and owns the message it handles")
end)

test.it("switches off a service whose update raises", function()
	local calls = 0
	---@param _ beat.ServiceInstance
	---@param _message beat.Message
	local function explode(_, _message)
		calls = calls + 1
		error("the service exploded")
	end
	---@type beat.Service
	local service = {
		needs = {},
		handles = { "bad:ping" },
		new = function() return {} end,
		update = explode,
	}

	local plugin = beat.plugin({
		name = "bad",
		version = "1.0.0",
		setup = function(handle) handle.service("bad:service", service) end,
	})
	App:init({ scan = false, plugins = { plugin } })

	App:act({ type = "bad:ping" })
	test.equal(calls, 1)
	test.truthy(reported("Plugin bad was switched off"), "the failure was reported")

	App:act({ type = "bad:ping" })
	test.equal(calls, 1, "the switched-off service is not updated again")
	App:act({ type = "toast", text = "after the failure" })
	test.truthy(reported("after the failure"), "the rest of the app still delivers messages")
end)

test.it("switches off a plugin whose hook raises, after one report, and carries on", function()
	local calls = 0
	local plugin = beat.plugin({
		name = "broken",
		version = "1.0.0",
		setup = function(handle)
			handle.wrap("page:home", function()
				calls = calls + 1
				error("the hook exploded")
			end)
		end,
	})
	App:init({ scan = false, plugins = { plugin } })

	local home = App.registry:page("home")
	test.equal(calls, 1, "the hook was called once")
	test.equal(type(home.view), "function", "the page it wrapped still works")

	App.registry:page("home")
	test.equal(calls, 1, "the switched-off plugin is not called again")
	test.truthy(reported("Plugin broken was switched off"), "the failure was reported")

	local reports = 0
	for _, toast in ipairs(App.services.toasts.list) do
		if toast.text:find("Plugin broken", 1, true) ~= nil then reports = reports + 1 end
	end
	test.equal(reports, 1, "it was reported once, not once per frame")

	App:act({ type = "toast", text = "still working" })
	test.truthy(reported("still working"), "the rest of the app still delivers messages")
end)

test.it("loads a bundle from the plugins folder and keeps the host's copy of a bundled module", function()
	writePlugin("probe.lua", PROBE)
	App:init({ scan = false })

	local probe = entry("probe")
	test.truthy(probe ~= nil, "the bundle is listed")
	test.equal(probe.state, "loaded")
	test.equal(probe.version, "2.3.4")
	test.equal(probe.builtin, false)
	test.equal(probe.source, path.join(paths.file("plugins"), "probe.lua"))

	local actions = App.registry:actions("album", { album = { id = 1 } })
	test.truthy(action(actions, "Private answer") ~= nil,
	"the plugin's own module was resolvable and its action was registered")

	---@diagnostic disable-next-line: missing-module
	local private = require("probe.private") --[[@as { answer: number, host: any }]]
	test.equal(private.answer, 42, "the plugin's private module is the one it shipped")
	test.equal(type(require("json").encode), "function", "beat's json is still beat's")
	test.equal(require("json").tampered, nil, "the bundle's bundled copy of json did not replace it")
	test.equal(private.host, require("json"), "the plugin sees the host module too")
end)

test.it("keeps starting when a plugin file raises, and lets a broken file be switched off", function()
	_G.__beat_broken_runs = nil
	writePlugin("broken.lua",
	'_G.__beat_broken_runs = (_G.__beat_broken_runs or 0) + 1\nerror("the bundle exploded")')
	App:init({ scan = false })

	local broken = entry("broken.lua")
	test.truthy(broken ~= nil, "the file is listed by its file name")
	test.equal(broken.state, "failed")
	test.truthy(broken.reason ~= nil and broken.reason:find("the bundle exploded", 1, true) ~= nil,
	"the error is kept for the page")
	test.truthy(reported("broken.lua was not loaded"), "the failure was reported")
	local core = assert(entry("core"))
	test.equal(core.state, "loaded", "the app still loaded its own plugins")
	test.equal(_G.__beat_broken_runs, 1, "the file ran once")

	-- A file that cannot load is the one most worth switching off, and the switch is its name.
	App:act({ type = "pluginEnabled", file = "broken.lua", enabled = false })
	App.services.settings:flush()
	App:init({ scan = false })

	local brokenOff = assert(entry("broken.lua"))
	test.equal(brokenOff.state, "off", "the next start lists it as off")
	test.equal(_G.__beat_broken_runs, 1, "and does not run the file again")
	_G.__beat_broken_runs = nil
end)

test.it("names bytecode from another LuaJIT as the likely reason it would not load", function()
	writePlugin("other.lua", "\27LJ\1\0not bytecode for this LuaJIT")
	App:init({ scan = false })

	local other = entry("other.lua")
	test.truthy(other ~= nil, "the file is listed by its file name")
	test.equal(other.state, "failed")
	local reason = assert(other.reason)
	test.truthy(reason:find("bytecode", 1, true) ~= nil,
	"the error says the file is bytecode")
	test.truthy(reason:find("same LuaJIT", 1, true) ~= nil,
	"and names the likely cause")
end)

test.it("lists a disabled file as off without running it", function()
	fs.write(paths.file("settings.json"), json.encode({ disabledPlugins = { "sleeper.lua" } }))
	writePlugin("sleeper.lua", [[
_G.__beat_sleeper_ran = true
package.preload["sleeper"] = function()
	return {
		name = "sleeper",
		version = "1.0.0",
		setup = function(beat)
			beat.action({
				menu = "album",
				title = "Sleeper action",
				message = { type = "toast", text = "woke" },
			})
		end,
	}
end
return package.preload["sleeper"](...)
]])
	App:init({ scan = false })

	local sleeper = entry("sleeper.lua")
	test.truthy(sleeper ~= nil, "the switched-off file is still listed by its file name")
	test.equal(sleeper.state, "off")
	test.equal(sleeper.disabled, true)
	test.equal(sleeper.version, nil, "the file was not run to learn its version")
	test.equal(sleeper.source, path.join(paths.file("plugins"), "sleeper.lua"))
	test.equal(_G.__beat_sleeper_ran, nil, "the disabled file was never executed")
	test.equal(action(App.registry:actions("album", { album = { id = 1 } }), "Sleeper action"), nil,
	"its setup never ran")
	test.equal(package.loaded["sleeper"], nil, "its modules were not kept")
	test.equal(package.preload["sleeper"], nil, "and cannot be required later")
	_G.__beat_sleeper_ran = nil
end)

test.it("saves a switch in disabledPlugins by file name and honours it on the next start", function()
	writePlugin("toggle.lua", [[
package.preload["toggle"] = function()
	return {
		name = "toggle",
		version = "1.0.0",
		setup = function(beat)
			beat.action({
				menu = "album",
				title = "Toggle action",
				message = { type = "toast", text = "toggled" },
			})
		end,
	}
end
return package.preload["toggle"](...)
]])
	App:init({ scan = false })
	local toggleLoaded = assert(entry("toggle"))
	test.equal(toggleLoaded.state, "loaded")

	App:act({ type = "pluginEnabled", file = "toggle.lua", enabled = false })
	App.services.settings:flush()

	local bytes = assert(fs.read(paths.file("settings.json")))
	local saved = json.decode(bytes):unpack()
	local disabled = {}
	for _, name in ipairs(saved.disabledPlugins) do disabled[name] = true end
	test.equal(disabled["toggle.lua"], true, "the switch was written to the settings file by file name")

	App:init({ scan = false })
	local toggleOff = assert(entry("toggle.lua"))
	test.equal(toggleOff.state, "off", "the next start reads the switch")
	test.equal(entry("toggle"), nil, "the disabled file is listed by its file name, not its plugin name")
	test.equal(action(App.registry:actions("album", { album = { id = 1} }), "Toggle action"), nil,
	"and the plugin is out of the app")
end)
