local ffi = require("ffi")
local wonderland = require("wonderland")
local ui = require("beat-ui")
local artwork = require("beat.music.artwork")
local fs = require("fs")

local shell = require("beat.app.shell")
local Registry = require("beat.app.registry")
local Plugins = require("beat.app.plugins")
local PluginFiles = require("beat.app.plugin_files")
local metrics = require("beat.app.components.helpers.metrics")
local settingsModel = require("beat.app.services.settings.model")
local ServiceCollection = require("beat.app.service_collection")
local Signal = require("beat.app.signal")

-- Written by build.lua from assets/icon-256.png, so a compiled binary carries it too.
local iconData = require("beat.app.icon")

-- The PNG decoded once: the window, its title bar and the tray all take the same bytes.
local iconCache

-- Beat's own plugins, by module name under `beat.plugins`. Each registers the services, pages and
-- overlays of one feature; outside plugins are loaded after them, from the config directory's
-- `plugins` folder, or through `opts.plugins` for a caller that supplies them itself.
local BUILT_IN = { "beat_ui", "core", "tasks", "plugins", "library", "collections", "playback", "lastfm" }

local MEDIA_MESSAGES = {
	playPause = "togglePlay",
	play = "play",
	pause = "pause",
	stop = "stop",
	next = "next",
	previous = "previous"
}

-- What the tray menu's playback items mean to the app: the same messages the player bar sends.
local TRAY_MESSAGES = {
	toggle = "togglePlay",
	next = "next",
	previous = "previous"
}

--- Where a navigation goes: a page kind and what picks the one page of that kind. `App:go` turns
--- it into a `beat.PageInstance`, which is what `App.page` and the history hold.
---@alias beat.Route
--- | { kind: "home" }
--- | { kind: "search" }
--- | { kind: "searchAll", category: "albums"|"artists"|"tracks" }
--- | { kind: "library" }
--- | { kind: "settings" }
--- | { kind: "plugins" }
--- | { kind: "folders" }
--- | { kind: "album", id: number }
--- | { kind: "artist", id: number }
--- | { kind: "playlists" }
--- | { kind: "playlist", id: number }

--- The app's services by name, each one made before everything that needs it.
---@class beat.Services
---@field appearance beat.AppearanceService
---@field collections beat.CollectionsService
---@field covers beat.CoversService
---@field equalizer beat.EqualizerService
---@field lastfm beat.LastfmService
---@field library beat.LibraryService
---@field motion beat.MotionService
---@field playback beat.PlaybackService
---@field scan beat.ScanService
---@field scroll beat.ScrollService
---@field search beat.SearchService
---@field settings beat.SettingsService
---@field sidebar beat.SidebarService
---@field system beat.SystemService
---@field tasks beat.TasksService
---@field toasts beat.ToastsService

--- The window calls the app makes that the layout's own window alias does not name: a backend may
--- have them or not, and the app asks for them where it can. Optional fields keep a plain
--- `wonderland.RenderWindow` — a headless stand-in, a test's table — accepted where one is handed
--- to a function that wants these.
--- The window's events as the app reads them. Wonderland hands the whole `winit.Event`; a test
--- writes only the fields the app looks at.
---@alias beat.AppEvent
--- | winit.Event
--- | { name: "windowClose" }
--- | { window: winit.Window, name: "minimize" }
--- | { window: winit.Window, name: "restore" }
--- | { window: winit.Window, name: "trayClick" }
--- | { window: winit.Window, name: "trayMenu", id: string }
--- | { name: "fileDrop", paths: string[]? }
--- | { name: "mediaKey", action: string }
--- | { name: "mousePress" }
--- | { name: "keyPress", key: winit.KeyName, modifiers: winit.KeyModifiers? }

---@class beat.WindowCalls
---@field setIcon (fun(self: wonderland.RenderWindow, width: number, height: number, rgba: string))?
---@field captureMediaKeys (fun(self: wonderland.RenderWindow): string[])?
---@field hide (fun(self: wonderland.RenderWindow))? # Off the screen and the taskbar; the loop and its media keys keep working
---@field show (fun(self: wonderland.RenderWindow))? # Back on screen, restored and in front
---@field setTray (fun(self: wonderland.RenderWindow, tray: winit.Tray))? # The notification-area icon and its menu
---@field removeTray (fun(self: wonderland.RenderWindow))? # Takes the icon away

---@class beat.App: wonderland.App
---@field window wonderland.RenderWindow?
---@field layoutPlugin wonderland.plugin.Layout?
---@field assets wonderland.Assets?
---@field page beat.PageInstance
---@field history beat.PageInstance[]
---@field future beat.PageInstance[]
---@field overlays beat.OverlayInstance<beat.OverlayState>[] # Open over the page, the last one on top
---@field ticker wonderland.plugin.UI.Ticker?
---@field iconSet boolean
---@field mediaKeysTaken boolean?
---@field trayShown boolean? # True while the minimize-to-tray icon is in the notification area
---@field instance beat.Instance? # The claim on the config directory this copy runs under; another launch asks through it for the window
---@field registry beat.Registry # What plugins registered, and what the app asks it for
---@field pluginStates beat.PluginStatus[] # Every plugin the page lists: loaded, off, failed, doesn't fit. Not `plugins`: that is wonderland's own list of its screen plugins, and the window's events are walked down it
---@field services beat.Services # The app's services by name: `app.services.search`
---@field serviceOrder beat.ServiceInstance[] # Every service, each after everything it needs
---@field owners table<string, beat.ServiceInstance> # The service that answers each message type
---@field messages beat.Signal # Every message, as it is delivered
---@field queue table[] # Messages waiting their turn
---@field delivering boolean
---@field uiContext { window: wonderland.RenderWindow, theme: beat.Theme, assets: wonderland.Assets?, width: number, height: number, contentWidth: number, contentHeight: number, mobile: boolean, focusedId: string?, context: beat.ui.Context }?
local App = wonderland.app("Beat")

--- Which page a route or a page is: two with the same key are the same page, and share where
--- they were scrolled to.
---@param page beat.PageKey
---@return string
function App:keyOf(page)
	local surface = self.registry:page(page.kind)
	return surface.key ~= nil ? surface.key(page) : page.kind
end

--- A page for a route, with the state its module starts it with.
---@param route beat.Route
---@return beat.PageInstance
function App:pageFor(route)
	---@type beat.PageInstance
	local page = { kind = route.kind, state = {} }
	for field, value in pairs(route) do page[field] = value end
	local surface = self.registry:page(page.kind)
	page.state = surface.new ~= nil and surface.new(self, page) or {}
	return page
end

--- The page showing, with its state. A page put in place without one -- a test sets `App.page`
--- to a bare route -- is given the state its module starts with.
---@return beat.PageInstance
function App:currentPage()
	local page = self.page
	if page.state == nil then
		local surface = self.registry:page(page.kind)
		page.state = surface.new ~= nil and surface.new(self, page) or {}
	end
	return page
end

--- Opens an overlay on top of the others. Its module may refuse -- the album it is for is gone
--- -- and then nothing opens.
---@param name string
---@param params table?
---@return beat.OverlayInstance?
function App:open(name, params)
	local state = self.registry:overlay(name).new(self, params or {})
	if state == nil then return nil end
	---@cast state beat.OverlayState
	---@type beat.OverlayInstance
	local overlay = { name = name, state = state }
	self.overlays[#self.overlays + 1] = overlay
	self:refresh()
	return overlay
end

--- Closes an overlay, or the topmost overlay with a name, and what was opened over it.
---@generic S: beat.OverlayState
---@param which beat.OverlayInstance<S>|string
function App:close(which)
	for at = #self.overlays, 1, -1 do
		local overlay = self.overlays[at]
		if overlay == which or overlay.name == which then
			for above = #self.overlays, at, -1 do
				local closing = assert(table.remove(self.overlays, above))
				local surface = self.registry:overlay(closing.name)
				if surface.close ~= nil then surface.close(self, closing) end
			end
			self:refresh()
			return
		end
	end
end

function App:closeOverlays()
	if #self.overlays > 0 then self:close(self.overlays[1]) end
end

--- The topmost open overlay with a name.
---@param name string
---@return beat.OverlayInstance<beat.OverlayState>?
function App:overlay(name)
	for at = #self.overlays, 1, -1 do
		if self.overlays[at].name == name then return self.overlays[at] end
	end
	return nil
end

--- What a page change or a new library takes away: every overlay, and whatever the page being
--- left keeps only while it is looked at.
function App:closeTransient()
	self:closeOverlays()
	local page = self.page
	if page ~= nil then
		local surface = self.registry:page(page.kind)
		if surface.leave ~= nil then surface.leave(self, self:currentPage()) end
	end
end

--- Beat's logo, decoded once for both the window's icon and the tray's: the same picture, and the
--- same bytes either backend takes.
---@return { width: number, height: number, rgba: string }?
function App:icon()
	if iconCache == nil then
		local icon = artwork.decodePNG(iconData)
		if icon == nil then return nil end
		iconCache = {
			width = icon.width,
			height = icon.height,
			rgba = ffi.string(icon.pixels, icon.width * icon.height * 4)
		}
	end
	return iconCache
end

--- Gives the window the logo as its icon, where the backend can take one. X11 reads it from the
--- `_NET_WM_ICON` property; a backend without `setIcon` leaves the window as it was.
---@param window wonderland.RenderWindow & beat.WindowCalls
function App:setIcon(window)
	if self.iconSet or window.setIcon == nil then return end

	local icon = self:icon()
	if icon == nil then return end

	window:setIcon(icon.width, icon.height, icon.rgba)
	self.iconSet = true
end

--- The window calls the media keys answer. Not every backend has them, so they are asked for
--- here rather than declared on the layout's window alias.
---@param window wonderland.RenderWindow & beat.WindowCalls
function App:takeMediaKeys(window)
	if self.mediaKeysTaken or window.captureMediaKeys == nil then return end
	self.mediaKeysTaken = true

	local refused = window:captureMediaKeys()
	if #refused > 0 then
		self:act(
			{
				type = "toast",
				tone = "error",
				text = "Another application is using the media keys: " .. table.concat(refused, ", ")
			}
		)
	end
end

--- The icon, tooltip and menu the notification area shows, from what is loaded and playing. The
--- tooltip names the track; the menu mirrors the player bar's controls, in the order a menu reads.
---@return winit.Tray?
function App:trayData()
	local icon = self:icon()
	if icon == nil then return nil end

	local playback = self.services.playback
	local current = playback:current()
	local tooltip = "beat"
	if current ~= nil then
		tooltip = current.artist ~= "" ? (current.title .. " – " .. current.artist) : current.title
	end

	return {
		icon = { width = icon.width, height = icon.height, rgba = icon.rgba },
		tooltip = tooltip,
		menu = {
			{ id = "toggle", label = playback.player:isPlaying() ? "Pause" : "Play" },
			{ id = "next", label = "Next" },
			{ id = "previous", label = "Previous" },
			{ separator = true },
			{ id = "show", label = "Show beat", default = true },
			{ id = "quit", label = "Quit" }
		}
	}
end

--- Keeps the icon in step with what is loaded and playing. Only while it is showing: a window
--- that was never minimized has no icon to update.
function App:updateTray()
	if not self.trayShown then return end
	local window = self.window
	if window == nil or window.setTray == nil then return end
	local tray = self:trayData()
	if tray ~= nil then window:setTray(tray) end
end

--- A minimized window goes off the screen and the taskbar, with its loop, media keys and sound
--- still running. The icon that brings it back goes into the notification area, and what the
--- services would have written on close is written now: the process may be killed while hidden.
---@param window wonderland.RenderWindow & beat.WindowCalls
function App:minimizeToTray(window)
	if window.hide == nil or window.setTray == nil then return end
	local tray = self:trayData()
	if tray == nil then return end
	self.window = window
	window:hide()
	self.trayShown = true
	window:setTray(tray)
	self:flush()
end

--- Brings a hidden window back, restored and in front, and takes the icon away. A click on the
--- icon and the menu's default item both come here.
---@param window wonderland.RenderWindow & beat.WindowCalls
function App:showFromTray(window)
	self.trayShown = false
	if window.show ~= nil then window:show() end
	if window.removeTray ~= nil then window:removeTray() end
end

--- What another launch of beat asks for: this copy's window, in front -- out of the tray if it is
--- there, up from the taskbar if it is minimized. A backend that cannot raise a window leaves it
--- where it is.
---@param window wonderland.RenderWindow & beat.WindowCalls
function App:bringForward(window)
	if self.trayShown then
		self:showFromTray(window)
	elseif window.show ~= nil then
		window:show()
	end
end

--- Writes what services keep until a moment later: a setting still settling, where listening got
--- to. The close button and the tray's Quit both take the app away, so both call this.
function App:flush()
	for _, service in ipairs(self.serviceOrder) do
		if service.flush ~= nil then service:flush() end
	end
end

---@param opts { scan: boolean?, plugins: table[]? }?
function App:init(opts)
	opts = opts or {}
	for _, service in ipairs(self.serviceOrder or {}) do
		if service.close ~= nil then service:close() end
	end
	self.queue = {}
	self.delivering = false
	self.uiContext = nil
	self.trayShown = nil
	self.messages = Signal.new()
	self.registry = Registry.new(self)
	-- Read once, before any service exists, because what is switched off decides which plugin
	-- files are only listed rather than loaded. The same values are handed to the settings
	-- service below, so a switch and the app never disagree about what is on.
	local settingsValues = settingsModel.load()
	local outside
	if opts.plugins ~= nil then
		-- A caller -- a test, the throwaway launcher -- supplied the plugins itself; the folder is
		-- not read, and what the folder's switches say does not apply to them.
		outside = {}
		for _, module in ipairs(opts.plugins) do
			outside[#outside + 1] = { module = module, source = "given to the app" }
		end
	else
		outside = PluginFiles.found(nil, settingsValues.disabledPlugins)
	end
	local _, entries = Plugins.load(self.registry, BUILT_IN, outside)
	self.pluginStates = entries
	local collection = ServiceCollection.new()
	---@type table<string, beat.Service>
	local modules = self.registry:serviceModules()
	for name, module in pairs(modules) do collection:add(name, module) end
	-- What services are given besides each other. `emit` sends a message the way a click does;
	-- it is delivered after the one being handled. `pointer` is where the pointer is in the window,
	-- and `window` is the one a native dialog is shown over: the two pieces of the shell a service
	-- has to ask about rather than own.
	collection:provide("emit", |message| -> self:act(message))
	collection:provide("messages", self.messages)
	collection:provide("options", opts)
	collection:provide("registry", self.registry)
	collection:provide("settingsValues", settingsValues)
	collection:provide("window", || -> self.window)
	collection:provide("pointer", function()
		if self.window == nil or self.layoutPlugin == nil then return nil end
		if self.layoutPlugin.pointer ~= nil then return self.layoutPlugin:pointer(self.window) end
		-- Older wonderland releases keep the pointer on the layout context itself.
		local contexts = self.layoutPlugin.contexts
		local context = contexts?.[self.window]
		return context?.pointer
	end)
	local services = collection:build()
	-- The plugin system's boundary: the registry builds services by the names it was given, and
	-- `beat.Services` is what those names mean to the rest of the app. Every built-in service is
	-- named here; an outside plugin can add more without changing this view.
	self.services = services.byName --[[@as beat.Services]]
	self.serviceOrder = services.order
	self.owners = services.owners
	-- From here a plugin that fails can say so in the window rather than only in the log.
	self.registry:attach(self.services)

	local values = self.services.settings.values

	self.history = {}
	self.future = {}
	self.overlays = {}

	-- After the library, so a page that reads it on opening sees it, and before the scan, whose
	-- reset message is delivered through the page that is showing.
	self.page = (self:pageFor({ kind = values.root == nil ? "folders" : "home" }))
	self.services.scan:resume()

	self.ticker = self:onTick(|now, window| -> self:tick(now, window))
end

function App:refresh()
	local window = self.window
	if window ~= nil then self:present(window) end
end

--- The UI context a component reads: the live theme, the window's box, the page's content box,
--- the phone breakpoint and where keyboard focus is. It is cached per window and input, so every
--- component in a frame shares one table rather than making its own.
---
--- This is the only beat API a plugin needs in order to draw with beat-ui:
--- `require("beat-ui").button(app:ui(window), props)`.
---@param window { width: number, height: number } # The window the frame is drawn for
---@return beat.ui.Context
function App:ui(window)
	local theme = self.services.appearance.theme
	local width, height = window.width, window.height
	local mobile = metrics.mobile(self, width)
	local contentWidth = metrics.contentWidth(self, width)
	-- Depends on whether something is playing (the player bar), so it is part of the cache key.
	local contentHeight = metrics.viewportHeight(self, width, height)
	local focusedId = nil
	if self.layoutPlugin ~= nil and self.layoutPlugin.getFocusedId ~= nil then
		focusedId = self.layoutPlugin:getFocusedId(window --[[@as wonderland.RenderWindow]])
	end

	local cached = self.uiContext
	if
		cached ~= nil
		and cached.window == window
		and cached.theme == theme
		and cached.assets == self.assets
		and cached.width == width
		and cached.height == height
		and cached.contentWidth == contentWidth
		and cached.contentHeight == contentHeight
		and cached.mobile == mobile
		and cached.focusedId == focusedId
	then
		return cached.context
	end

	local context = ui.Context.new({
		theme = theme,
		assets = self.assets,
		width = width,
		height = height,
		contentWidth = contentWidth,
		contentHeight = contentHeight,
		mobile = mobile,
		focusedId = focusedId
	} --[[@as beat.ui.ContextValues]])
	self.uiContext = {
		window = window,
		theme = theme,
		assets = self.assets,
		width = width,
		height = height,
		contentWidth = contentWidth,
		contentHeight = contentHeight,
		mobile = mobile,
		focusedId = focusedId,
		context = context
	}
	return context
end

--- Put the caret in a dialog's field as soon as it opens, so typing is the next thing that
--- happens rather than a click into the field first.
---@param name string?
---@param at number? # Where the caret starts, at the end of a value that was already typed
function App:focusField(name, at)
	if self.layoutPlugin ~= nil and self.window ~= nil then
		self.layoutPlugin:setFocus(self.window, name)
		if name ~= nil and at ~= nil then
			self.layoutPlugin:setCaret(self.window, 0, at)
		end
	end
end

---@return string
function App:pageKey()
	return self:keyOf(self.page)
end

--- A ticker asleep for the idle interval still has a frame to show when something starts
--- moving: a page slide, a toast, a theme fade. Wake it now rather than waiting for the next
--- idle tick, which is later than the animation itself.
function App:wake()
	if self.ticker ~= nil then self.ticker.due = 0 end
end

---@param route beat.Route
---@param keepFocus boolean? # Whether a field already being typed in keeps the keyboard across the page change
function App:go(route, keepFocus)
	if self:keyOf(route) == self:pageKey() then
		-- A click on the page already showing does not navigate, but it must still not leave a
		-- transition from a moment ago frozen on its first frame.
		self:wake()
		return
	end

	self:closeTransient()
	if not keepFocus then self:focusField(nil) end
	self.history[#self.history + 1] = self.page
	self.future = {}

	self.page = self:pageFor(route)
	self.services.motion:slide(1)
	self:wake()
	self:refresh()
end

--- Back and forward bring a page back as it was left: its state comes with it.
---@param from beat.PageInstance[]
---@param to beat.PageInstance[]
---@param direction number
function App:travel(from, to, direction)
	if #from == 0 then return end
	to[#to + 1] = self.page
	self:closeTransient()
	self:focusField(nil)
	self.page = assert(table.remove(from))
	self.services.motion:slide(direction)
	self:wake()
	self:refresh()
end

function App:back()
	self:travel(self.history, self.future, -1)
end

function App:forward()
	self:travel(self.future, self.history, 1)
end

-- ────────────────────────────────────────────────────────────────
-- messages
-- ────────────────────────────────────────────────────────────────

--- Every message goes through here: clicks, what the window's events turn into, and what services
--- emit. A message that causes messages waits its turn, so nothing is handled halfway through
--- something else.
---@param message any
function App:act(message)
	if type(message) ~= "table" or message.type == nil then return end
	self.queue[#self.queue + 1] = message
	if self.delivering then return end

	self.delivering = true
	local delivered = 0
	while #self.queue > 0 do
		delivered += 1
		if delivered > 64 then
			local stuck = self.queue[1].type
			self.queue = {}
			self.delivering = false
			error("messages kept causing messages: " .. tostring(stuck))
		end
		local next = table.remove(self.queue, 1)
		self.messages:fire(next)
		self:deliver(next)
	end
	self.delivering = false

	-- Whatever the message changed is worth a frame now rather than one at the idle interval,
	-- which is longer than the animations it starts.
	self:wake()
	-- While the window sits in the tray the menu names the track and its play state, so a message
	-- that changes either also refreshes the icon.
	self:updateTray()
end

--- Hands a message to whatever it is for: the overlays from the top down, then the page, then the
--- one service that answers its type, then the router. A light overlay a message passes over is
--- closed by it -- a menu goes away when anything else is pressed -- and a dialog stays. `keep` is
--- a press on an overlay's own panel, which does nothing; `dismiss` is a press beside it, which
--- closes the top one. A local function rather than a method: `dispatch` is wonderland's, and it
--- is what turns the window's events into messages.
---@param app beat.App
---@param message table
local function deliverTo(app, message)
	if message.type == "keep" then return end
	if message.type == "dismiss" or (message.type == "escape" and #app.overlays > 0) then
		local top = app.overlays[#app.overlays]
		if top ~= nil then app:close(top) end
		return
	end

	local at = #app.overlays
	while at >= 1 do
		local overlay = app.overlays[at]
		local surface = app.registry:overlay(overlay.name)
		if surface.update ~= nil and surface.update(app, overlay, message) then return end
		if surface.light and app.overlays[at] == overlay then app:close(overlay) end
		at = math.min(at - 1, #app.overlays)
	end

	local page = app:currentPage()
	local surface = app.registry:page(page.kind)
	if surface.update ~= nil and surface.update(app, page, message) then return end

	local owner = app.owners[message.type]
	if owner ~= nil then
		owner:update(message)
		app:refresh()
		return
	end

	app:route(message)
end

--- Takes a message through the interceptors that asked to see its type, then hands it to whatever
--- it is for, then tells the listeners that it has been delivered. An interceptor that does not
--- call `continue` stops the message before it reaches anything.
---@param message beat.Message
function App:deliver(message)
	local proceed, current = self.registry:intercept(message, self)
	if not proceed then return end
	deliverTo(self, current)
	self.registry:notify(current, self)
end

--- The router's own messages: where the app is, not what it is about.
---   navigate  { page = route, keepFocus? }  go to a page
---   back, forward                           through the history
---   reset     { page = route }              go to a page and forget how the app got anywhere
---   open      { overlay = name, ... }        open an overlay with the rest of the message
---   focus     { field = name, at? }         give a named field the keyboard
---   escape                                  nothing was open and the page did not want it: back
---@param message table
function App:route(message)
	if message.type == "navigate" then
		self:go(message.page, message.keepFocus == true)
	elseif message.type == "back" or message.type == "escape" then
		self:back()
	elseif message.type == "forward" then
		self:forward()
	elseif message.type == "reset" then
		self:closeTransient()
		self:focusField(nil)
		self.history, self.future = {}, {}
		self.page = self:pageFor(message.page)
		self:refresh()
	elseif message.type == "open" then
		self:open(message.overlay, message)
	elseif message.type == "focus" then
		self:focusField(message.field, message.at)
	end
end

---@param message any
---@param _window winit.Window
function App:update(message, _window)
	self:act(message)
end

--- What the window's own events mean to the app, as messages: the app decides nothing here.
---@param event beat.AppEvent
---@param handler winit.EventManager
function App:event(event, handler)
	if event.name == "windowClose" then
		-- The app goes with the window. What its services would have written a moment from now --
		-- a setting still settling, where listening got to -- is written now.
		self:flush()
		return nil
	end

	local window = event.window or self.window

	if event.name == "minimize" then
		if window ~= nil and self.services.settings.values.minimizeToTray then
			---@cast window wonderland.RenderWindow & beat.WindowCalls
			self:minimizeToTray(window)
		end
		return nil
	end

	if event.name == "trayClick" then
		if window ~= nil then
			---@cast window wonderland.RenderWindow & beat.WindowCalls
			self:showFromTray(window)
		end
		return nil
	end

	if event.name == "trayMenu" then
		if event.id == "show" then
			if window ~= nil then
				---@cast window wonderland.RenderWindow & beat.WindowCalls
				self:showFromTray(window)
			end
		elseif event.id == "quit" then
			-- The same write the close button does, then the loop stops: nothing is left to save.
			self:flush()
			handler:exit()
		else
			local messageType = TRAY_MESSAGES[event.id]
			if messageType ~= nil then self:act({ type = messageType }) end
		end
		return nil
	end

	if event.name == "fileDrop" then
		for _, drop in ipairs(event.paths or {}) do
			if fs.isdir(drop) then
				self:act({ type = "startScan", root = drop })
				return nil
			end
		end
		self:act({ type = "toast", text = "Drop a folder to build a library", tone = "error" })
		return nil
	end

	if event.name == "mousePress" then
		-- A press on the search field changes layout focus without producing a message. The
		-- focus ring is drawn from that state, so ask for the frame that shows it.
		self:refresh()
		return nil
	end

	if event.name == "mediaKey" then
		local messageType = MEDIA_MESSAGES[event.action]
		if messageType ~= nil then self:act({ type = messageType }) end
		return nil
	end

	if event.name ~= "keyPress" then return nil end
	local key = event.key
	local modifiers = event.modifiers or {}

	if key == "space" then
		self:act({ type = "togglePlay" })
	elseif key == "left" then
		self:act({ type = "seek", by = -5 })
	elseif key == "right" then
		self:act({ type = "seek", by = 5 })
	elseif key == "escape" then
		self:act({ type = "escape" })
	elseif key == "/" or (modifiers.ctrl and key == "f") then
		self:act({ type = "openSearch" })
	elseif modifiers.ctrl and key == "o" then
		self:act({ type = "chooseFolder" })
	elseif modifiers.ctrl and key == "," then
		self:act({ type = "navigate", page = { kind = "settings" } })
	end

	self:refresh()
	return nil
end

-- ────────────────────────────────────────────────────────────────
-- the ticker
-- ────────────────────────────────────────────────────────────────

---@param now number
---@param window wonderland.RenderWindow
---@return number
function App:tick(now, window)
	self.window = window
	if self.instance ~= nil and self.instance:poll() then
		---@cast window wonderland.RenderWindow & beat.WindowCalls
		self:bringForward(window)
	end
	local changed, serviceBusy = false, false
	-- Each service does what it does on its own -- a scan coming in, a toast fading -- in the
	-- order they were made, so a service steps after everything it depends on.
	for _, service in ipairs(self.serviceOrder) do
		if service.step ~= nil then
			local stepChanged, stepBusy = service:step(now)
			if stepChanged then changed = true end
			if stepBusy then serviceBusy = true end
		end
	end

	if changed then self:present(window) end
	return serviceBusy and (1 / 60) or 0.5
end

---@param window wonderland.RenderWindow
---@param assets wonderland.Assets
---@return wonderland.Element
function App:view(window, assets)
	self.window = window
	self:setIcon(window)
	self:takeMediaKeys(window)
	self.assets = assets
	self.services.covers:use(assets)
	return shell.view(self, window)
end

return App
