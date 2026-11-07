local ffi = require("ffi")
local wonderland = require("wonderland")
local core = require("beat-core")
local fs = require("fs")

local shell = require("beat.app.shell")
local surfaces = require("beat.app.surfaces")
local ServiceCollection = require("beat.app.service_collection")
local Signal = require("beat.app.signal")

-- Written by build.lua from assets/icon-256.png, so a compiled binary carries it too.
local iconData = require("beat.app.icon")

-- The app's services, by name: `beat.app.services.<name>`. The order they are made in is worked
-- out from what each one needs, so this is a set -- the order it is written in does nothing.
local SERVICES = {
	"settings", "motion", "appearance", "toasts", "scroll",
	"library", "covers", "collections", "sidebar", "playback", "scan", "search",
	"lastfm", "system",
}

--- Where a navigation goes: a page kind and what picks the one page of that kind. `App:go` turns
--- it into a `beat.PageInstance`, which is what `App.page` and the history hold.
---@alias beat.Route
--- | { kind: "home" }
--- | { kind: "search" }
--- | { kind: "searchAll", category: "albums"|"artists"|"tracks" }
--- | { kind: "library" }
--- | { kind: "settings" }
--- | { kind: "folders" }
--- | { kind: "album", id: number }
--- | { kind: "artist", id: number }
--- | { kind: "playlists" }
--- | { kind: "playlist", id: number }

---@class beat.App: wonderland.App
---@field window wonderland.RenderWindow?
---@field layoutPlugin wonderland.plugin.Layout?
---@field assets wonderland.Assets?
---@field page beat.PageInstance
---@field history beat.PageInstance[]
---@field future beat.PageInstance[]
---@field overlays beat.OverlayInstance[] # Open over the page, the last one on top
---@field ticker table?
---@field iconSet boolean
---@field services table<string, table> # The app's services by name: `app.services.search`
---@field serviceOrder table[] # Every service, each after everything it needs
---@field owners table<string, table> # The service that answers each message type
---@field messages beat.Signal # Every message, as it is delivered
---@field queue table[] # Messages waiting their turn
---@field delivering boolean
local App = wonderland.app("Beat")

--- Which page a route or a page is: two with the same key are the same page, and share where
--- they were scrolled to.
---@param page beat.Route|beat.PageInstance
---@return string
function App:keyOf(page)
	local surface = surfaces.page(page.kind)
	return surface.key ~= nil and surface.key(page --[[@as beat.PageInstance]]) or page.kind
end

--- A page for a route, with the state its module starts it with.
---@param route beat.Route
---@return beat.PageInstance
function App:pageFor(route)
	---@type beat.PageInstance
	local page = { kind = route.kind, state = {}}
	for field, value in pairs(route) do page[field] = value end
	local surface = surfaces.page(page.kind)
	page.state = surface.new ~= nil and surface.new(self, page) or {}
	return page
end

--- The page showing, with its state. A page put in place without one -- a test sets `App.page`
--- to a bare route -- is given the state its module starts with.
---@return beat.PageInstance
function App:currentPage()
	local page = self.page
	if page.state == nil then
		local surface = surfaces.page(page.kind)
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
	local state = surfaces.overlay(name).new(self, params or {})
	if state == nil then return nil end
	---@type beat.OverlayInstance
	local overlay = { name = name, state = state}
	self.overlays[#self.overlays + 1] = overlay
	self:refresh()
	return overlay
end

--- Closes an overlay, or the topmost overlay with a name, and what was opened over it.
---@param which beat.OverlayInstance|string
function App:close(which)
	for at = #self.overlays, 1, -1 do
			local overlay = self.overlays[at]
			if overlay == which or overlay.name == which then
				for above = #self.overlays, at, -1 do
						local closing = table.remove(self.overlays, above)
						local surface = surfaces.overlay(closing.name)
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
---@return beat.OverlayInstance?
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
		local surface = surfaces.page(page.kind)
		if surface.leave ~= nil then surface.leave(self, self:currentPage()) end
	end
end

--- Gives the window the logo as its icon, where the backend can take one. X11 reads it from the
--- `_NET_WM_ICON` property; a backend without `setIcon` leaves the window as it was.
---@param window wonderland.RenderWindow
function App:setIcon(window)
	if self.iconSet or window.setIcon == nil then return end

	local icon = core.art.decodePNG(iconData)
	if icon == nil then return end

	window:setIcon(icon.width, icon.height, ffi.string(icon.pixels, icon.width * icon.height * 4))
	self.iconSet = true
end

---@param opts { scan: boolean? }?
function App:init(opts)
	for _, service in ipairs(self.serviceOrder or {}) do
			if service.close ~= nil then service:close() end
		end
	self.queue = {}
	self.delivering = false
	self.messages = Signal.new()
	local collection = ServiceCollection.new()
	for _, name in ipairs(SERVICES) do collection:add(name, require("beat.app.services." .. name)) end
	-- What services are given besides each other. `emit` sends a message the way a click does;
	-- it is delivered after the one being handled. `pointer` is where the pointer is in the window,
	-- and `window` is the one a native dialog is shown over: the two pieces of the shell a service
	-- has to ask about rather than own.
	collection:provide("emit", function(message) self:act(message) end)
	collection:provide("messages", self.messages)
	collection:provide("options", opts or {})
	collection:provide("window", function() return self.window end)
	collection:provide("pointer", function()
		if self.window == nil or self.layoutPlugin == nil then return nil end
		if self.layoutPlugin.pointer ~= nil then return self.layoutPlugin:pointer(self.window) end
		-- Older wonderland releases keep the pointer on the layout context itself.
		local contexts = self.layoutPlugin.contexts
		local context = contexts and contexts[self.window]
		return context and context.pointer or nil
	end)
	local services = collection:build()
	self.services = services.byName
	self.serviceOrder = services.order
	self.owners = services.owners

	local values = self.services.settings.values

	self.history = {}
	self.future = {}
	self.overlays = {}

	-- After the library, so a page that reads it on opening sees it, and before the scan, whose
	-- reset message is delivered through the page that is showing.
	self.page = self:pageFor({ kind = values.root == nil and "folders" or "home"})
	self.services.scan:resume()

	self.ticker = self:onTick(function(now, window) return self:tick(now, window) end)
end

function App:refresh()
	local window = self.window
	if window ~= nil then self:present(window) end
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
	self.page = table.remove(from)
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
			delivered = delivered + 1
			-- Services asking each other for something forever is a bug, and it should say so.
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
end

--- Hands a message to whatever it is for: the overlays from the top down, then the page, then the
--- one service that answers its type, then the router. A light overlay a message passes over is
--- closed by it -- a menu goes away when anything else is pressed -- and a dialog stays. `keep` is
--- a press on an overlay's own panel, which does nothing; `dismiss` is a press beside it, which
--- closes the top one. Not `dispatch`: that is wonderland's, and it is what turns the window's
--- events into messages.
---@param message table
function App:deliver(message)
	local kind = message.type
	if kind == "keep" then return end
	if kind == "dismiss" or (kind == "escape" and #self.overlays > 0) then
		local top = self.overlays[#self.overlays]
		if top ~= nil then self:close(top) end
		return
	end

	local at = #self.overlays
	while at >= 1 do
			local overlay = self.overlays[at]
			local surface = surfaces.overlay(overlay.name)
			if surface.update ~= nil and surface.update(self, overlay, message) then return end
			if surface.light and self.overlays[at] == overlay then self:close(overlay) end
			at = math.min(at - 1, #self.overlays)
		end

	local page = self:currentPage()
	local surface = surfaces.page(page.kind)
	if surface.update ~= nil and surface.update(self, page, message) then return end

	local owner = self.owners[kind]
	if owner ~= nil then
		owner:update(message)
		self:refresh()
		return
	end

	self:route(message)
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
	local kind = message.type
	if kind == "navigate" then
		self:go(message.page, message.keepFocus == true)
	elseif kind == "back" or kind == "escape" then
		self:back()
	elseif kind == "forward" then
		self:forward()
	elseif kind == "reset" then
		self:closeTransient()
		self:focusField(nil)
		self.history, self.future = {}, {}
		self.page = self:pageFor(message.page)
		self:refresh()
	elseif kind == "open" then
		self:open(message.overlay, message)
	elseif kind == "focus" then
		self:focusField(message.field, message.at)
	end
end

---@param message any
---@param _window winit.Window
function App:update(message, _window)
	self:act(message)
end

--- What the window's own events mean to the app, as messages: the app decides nothing here.
---@param event winit.Event
---@param handler winit.EventManager
function App:event(event, _handler)
	if event.name == "fileDrop" then
		for _, drop in ipairs(event.paths or {}) do
				if fs.isdir(drop) then
					self:act({ type = "startScan", root = drop})
					return nil
				end
			end
		self:act({ type = "toast", text = "Drop a folder to build a library", tone = "error"})
		return nil
	end

	if event.name == "mousePress" then
		-- A press on the search field changes layout focus without producing a message. The
		-- focus ring is drawn from that state, so ask for the frame that shows it.
		self:refresh()
		return nil
	end

	if event.name ~= "keyPress" then return nil end
	local key = event.key
	local modifiers = event.modifiers or {}

	if key == "space" then
		self:act({ type = "togglePlay"})
	elseif key == "left" then
		self:act({ type = "seek", by = -5})
	elseif key == "right" then
		self:act({ type = "seek", by = 5})
	elseif key == "escape" then
		self:act({ type = "escape"})
	elseif key == "/" or (modifiers.ctrl and key == "f") then
		self:act({ type = "openSearch"})
	elseif modifiers.ctrl and key == "o" then
		self:act({ type = "chooseFolder"})
	elseif modifiers.ctrl and key == "," then
		self:act({ type = "navigate", page = { kind = "settings"}})
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
	self.assets = assets
	self.services.covers:use(assets)
	return shell.view(self, window)
end

return App
