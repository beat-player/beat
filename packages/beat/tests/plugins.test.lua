-- What a plugin can add to beat from outside, and what happens when it cannot: menu entries,
-- message hooks, overlays, versions that do not match, names that are not its own, and a mistake
-- that must not take the app with it. The app is built headlessly, so nothing here needs a window.
local test = require("lde-test")
local fs = require("fs")
local wonderland = require("wonderland")
local paths = require("beat.paths")
local Library = require("beat.music.library")
local App = require("beat.app")

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
	if App.services ~= nil and App.services.playback ~= nil then App.services.playback.player:close() end
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

---@param ctx { album: beat.Album }
---@return beat.Message
local function openInRateYourMusic(ctx)
	return { type = "openURL", url = "https://rateyourmusic.com/album/" .. ctx.album.id }
end

test.it("adds an album action whose message reaches the service it names", function()
	---@type beat.PluginModule
	local plugin = {
		name = "rym",
		version = "1.0.0",
		setup = function(beat)
			beat.action({
				menu = "album",
				title = "Open in Rate Your Music",
				message = openInRateYourMusic,
			})
		end,
	}
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
	---@type beat.PluginModule
	local plugin = {
		name = "shuffler",
		version = "1.0.0",
		setup = function(beat)
			beat.intercept("playAlbum", shuffleFirst)
		end,
	}
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
	---@type beat.PluginModule
	local plugin = {
		name = "listener",
		version = "1.0.0",
		setup = function(beat)
			beat.on("trackStarted", noteStart)
		end,
	}
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
	---@type beat.PluginModule
	local plugin = {
		name = "panel",
		version = "1.0.0",
		setup = function(beat)
			beat.overlay("panel:card", { new = panelCard })
		end,
	}
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
	---@type beat.PluginModule
	local plugin = {
		name = "sloppy",
		version = "1.0.0",
		setup = function(beat)
			beat.action({
				menu = "album",
				title = "Should be rolled back",
				message = { type = "toast", text = "never" },
			})
			beat.page("home", { view = function() return wonderland.div() end })
		end,
	}
	App:init({ scan = false, plugins = { plugin } })

	test.equal(action(App.registry:actions("album", { album = { id = 1 } }), "Should be rolled back"), nil,
	"the registrations made before the bad page were taken back")
	test.equal(App.registry:page("home"), require("beat.app.pages.home"), "the built-in page is still there")
	test.truthy(reported("must be named"), "the reason was reported")
end)

test.it("adds a page a plugin named after itself", function()
	---@type beat.PluginModule
	local plugin = {
		name = "panel",
		version = "1.0.0",
		setup = function(beat)
			beat.page("panel:page", {
				new = function() return { hello = true } end,
				view = function() return wonderland.div() end,
			})
		end,
	}
	App:init({ scan = false, plugins = { plugin } })

	App:act({ type = "navigate", page = { kind = "panel:page" }})
	test.equal(App.page.kind, "panel:page", "the namespaced page is navigated to")
	test.equal(App:currentPage().state.hello, true, "it was given the state its surface starts with")
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

	---@type beat.PluginModule
	local plugin = {
		name = "counter",
		version = "1.0.0",
		setup = function(beat) beat.service("counter:service", service) end,
	}
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

	---@type beat.PluginModule
	local plugin = {
		name = "bad",
		version = "1.0.0",
		setup = function(beat) beat.service("bad:service", service) end,
	}
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
	---@type beat.PluginModule
	local plugin = {
		name = "broken",
		version = "1.0.0",
		setup = function(beat)
			beat.wrap("page:home", function()
				calls = calls + 1
				error("the hook exploded")
			end)
		end,
	}
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
