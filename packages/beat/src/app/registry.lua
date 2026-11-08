-- What plugins add to the app, and what the app asks for it: services, pages, overlays, menu
-- entries, message listeners and interceptors. A registration remembers the plugin that made it,
-- so an outside plugin that cannot load takes its own registrations back, and one that fails later
-- can be switched off without touching anyone else's.
--
-- `wrap` and `replace` are how a plugin changes what another plugin registered. A wrap sees the
-- value it is changing and returns a new one; a replace ignores it. Both are kept in the order
-- they were registered and applied when the value is asked for, so a page is never frozen into
-- whichever plugin happened to look at it first.
local Log = require("beat.log")
local messages = require("beat.message")

--- What a page keeps while it is showing and while it waits in the history. Each page module
--- declares its own state class, and `new` returns it.
---@class beat.PageState: table<string, any>

--- A page of the app, found by its route kind rather than by a module name. `S` is the state the
--- page module declares; `App.page` and the history hold one without naming it.
---@class beat.PageInstance<S: beat.PageState = beat.PageState>
---@field kind string
---@field id number?
---@field category string?
---@field state S

--- What picks the one page of a kind: the kind itself, and the id or category that tells two
--- pages of it apart. A route and the page it becomes both have these.
---@class beat.PageKey
---@field kind string
---@field id number?
---@field category string?

---@class beat.PageSurface
---@field key (fun(page: beat.PageKey): string)? # Which page this is, for scroll and for not navigating to itself; the kind when absent
---@field new (fun(app: beat.App, page: beat.PageInstance): beat.PageState?)? # The state a page starts with
---@field update (fun(app: beat.App, page: beat.PageInstance, message: beat.Message): boolean?)? # True when the message was this page's
---@field leave (fun(app: beat.App, page: beat.PageInstance))? # What the page drops when it is left
---@field view fun(app: beat.App, page: beat.PageInstance, window: wonderland.RenderWindow): wonderland.Element

--- What an overlay keeps while it is open. Each overlay declares its own state class and `new`
--- returns it; the registry only carries it.
---@class beat.OverlayState: table<string, any>

--- What a screen passes an overlay when it opens it: the message that asked, or the values a
--- test opens it with.
---@class beat.OverlayParams: table<string, any>
---@field type string?

--- An overlay on the stack above the page. `S` is the state its module declares.
---@class beat.OverlayInstance<S: beat.OverlayState = beat.OverlayState>
---@field name string
---@field state S

---@class beat.OverlaySurface
---@field light boolean? # Closes on any message it does not handle itself: menus and popovers. A dialog is not light.
---@field anchored boolean? # Drawn by the screen that opened it, at the button that opened it, rather than by the shell
---@field fullscreen boolean? # Is the screen while it is open: the page and the shell around it are not drawn
---@field new fun(app: beat.App, params: beat.OverlayParams): beat.OverlayState? # The overlay's state, or nil to refuse to open
---@field update (fun(app: beat.App, overlay: beat.OverlayInstance<beat.OverlayState>, message: beat.Message): boolean?)? # True when the message was this overlay's
---@field view (fun(app: beat.App, overlay: beat.OverlayInstance<beat.OverlayState>, window: wonderland.RenderWindow): wonderland.Element?)?
---@field close (fun(app: beat.App, overlay: beat.OverlayInstance<beat.OverlayState>))? # What closing it undoes: a focused field, a draft

--- What a context-menu action is made for. A menu sets the one field it was opened on — an album,
--- a track, a playlist — and a callback reads that field; the menu name says which one is there.
---@class beat.MenuContext: table<string, any>
---@field message beat.Messages # Message constructors for the action's return
---@field album beat.Album?
---@field track beat.Track?
---@field playlist beat.Playlist?

--- A destination in the sidebar and the phone's tabs, after the built-in ones.
---@class beat.NavEntry
---@field id string # The plugin's name and the entry's own: `bandcamp:search`
---@field title string
---@field icon string # A glyph name from `components/icon.lua`
---@field page beat.Route
---@field order number?

--- One entry of a context menu. The message may be made when the menu opens, so it can name the
--- album or track the menu is for.
---@class beat.Action
---@field menu string
---@field title string
---@field order number?
---@field tone string? # A colour name from the theme; `danger` is the one built-in menus use
---@field when (fun(ctx: beat.MenuContext, app: beat.App): boolean?)?
---@field message beat.Message|fun(ctx: beat.MenuContext, app: beat.App): beat.Message?

--- An action as the registry keeps it: the entry it was, the plugin that made it, and where it
--- sits in registration order.
---@class beat.ActionEntry
---@field menu string
---@field title string
---@field order number
---@field tone string?
---@field when (fun(ctx: table, app: beat.App): boolean?)?
---@field message beat.Message|fun(ctx: table, app: beat.App): beat.Message?
---@field plugin beat.Plugin
---@field index number

--- One change a plugin asked for: a wrap sees the value it changes, a replace does not.
---@class beat.Wrap
---@field kind "wrap"
---@field fn fun(original: any): any
---@field plugin beat.Plugin

---@class beat.Replace
---@field kind "replace"
---@field value any
---@field plugin beat.Plugin

---@alias beat.Mod beat.Wrap|beat.Replace

--- One listener or interceptor, and the plugin it belongs to.
---@class beat.ListenerEntry
---@field fn fun(message: beat.Message, app: beat.App)
---@field plugin beat.Plugin

---@class beat.InterceptorEntry
---@field fn fun(message: beat.Message, app: beat.App, continue: fun(message: beat.Message?))
---@field plugin beat.Plugin

--- A plugin while it is loaded, and what the plugins page shows about it. Built-in plugins are
--- not protected: their mistakes are the app's.
---@class beat.Plugin
---@field name string
---@field version string
---@field builtin boolean
---@field disabled boolean
---@field source string # "built-in", or the file outside plugins were read from
---@field file string? # The plugins-folder file, when this plugin came from one
---@field state "loaded"|"off"|"failed"|"doesn't fit"|"switched off"
---@field reason string? # Why it is not loaded, or why it was switched off

--- What a plugin module declares before it is loaded. `setup` is handed the handle that records
--- everything it registers, so a plugin that cannot finish is taken back out of the app whole.
---@class beat.PluginModule
---@field name string
---@field version string
---@field requires table<string, string>? # Plugin name to the version it needs
---@field setup fun(handle: beat.PluginHandle)

--- What a plugin registers through: one function per kind of registration, each answering the
--- undo that takes it out again.
---@class beat.PluginHandle
---@field msg beat.Messages
---@field service fun(name: string, module: beat.Service)
---@field page fun(kind: string, surface: beat.PageSurface)
---@field overlay fun(name: string, surface: beat.OverlaySurface)
---@field action fun(action: beat.Action)
---@field on fun(kind: string, listener: fun(message: table, app: beat.App))
---@field intercept fun(kind: string, interceptor: fun(message: table, app: beat.App, continue: fun(message: table?)))
---@field wrap fun(name: string, fn: fun(original: any): any)
---@field replace fun(name: string, value: any)

---@class beat.Registration
---@field value any
---@field plugin beat.Plugin
---@field handles string[]?

---@class beat.Registry
---@field app beat.App
---@field plugins beat.Plugin[]
---@field services table<string, beat.Registration>
---@field pages table<string, beat.Registration>
---@field overlays table<string, beat.Registration>
---@field mods table<string, beat.Mod[]> # By `page:home`, `overlay:queue`, `service:playback`
---@field handled table<string, beat.Registration> # The service that answers each message type
---@field actionsList beat.ActionEntry[] # In registration order; sorted when a menu asks
---@field navList table[] # Sidebar entries in registration order; sorted when a sidebar asks
---@field listeners table<string, beat.ListenerEntry[]>
---@field interceptors table<string, beat.InterceptorEntry[]>
---@field reports string[] # Problems found before the toasts service could be told
---@field toasts beat.ToastsService?
local Registry = {}
Registry.__index = Registry

---@type table<string, string>
local KINDS = { service = "services", page = "pages", overlay = "overlays" }

---@param app beat.App
---@return beat.Registry
function Registry.new(app)
	return setmetatable(
		{
			app = app,
			plugins = {},
			services = {},
			pages = {},
			overlays = {},
			mods = {},
			handled = {},
			actionsList = {},
			navList = {},
			listeners = {},
			interceptors = {},
			reports = {},
			toasts = nil
		},
		Registry
	)
end

---@param text string
function Registry:report(text)
	if self.toasts ~= nil then
		self.toasts:show(text, "error")
		return
	end
	self.reports[#self.reports + 1] = text
end

--- The services are built; from now on a problem can be shown rather than only written down.
---@param services beat.Services
function Registry:attach(services)
	self.toasts = services.toasts
	local reports = self.reports
	self.reports = {}
	for _, text in ipairs(reports) do
		if self.toasts ~= nil then
			self.toasts:show(text, "error")
		else
			Log.write("error", text)
		end
	end
end

--- A plugin that raised is not called again. It is reported once; the app carries on with the
--- registrations it already has, because taking a running service out from under the app would
--- fail harder than the mistake did.
---@param plugin beat.Plugin
---@param err any
function Registry:disable(plugin, err)
	if plugin.builtin then error(err, 0) end
	if plugin.disabled then return end
	plugin.disabled = true
	plugin.state = "switched off"
	plugin.reason = tostring(err)
	self:report("Plugin " .. plugin.name .. " was switched off: " .. tostring(err))
end

---@param kind string
---@param name string
---@param plugin beat.Plugin
local function namespace(plugin, kind, name)
	if plugin.builtin then return end
	local prefix = plugin.name .. ":"
	if name:sub(1, #prefix) ~= prefix then
		error("a plugin's " .. kind .. " must be named " .. prefix .. "...: " .. name, 0)
	end
end

---@param value any
---@return boolean
---@return string?
local function pageShape(value)
	if type(value) ~= "table" then return false, "a page must be a table" end
	if type(value.view) ~= "function" then return false, "a page needs view(app, page, window)" end
	return true
end

---@param value any
---@return boolean
---@return string?
local function overlayShape(value)
	if type(value) ~= "table" then return false, "an overlay must be a table" end
	if type(value.new) ~= "function" then return false, "an overlay needs new(app, params)" end
	return true
end

---@param value any
---@return boolean
---@return string?
local function serviceShape(value)
	if type(value) ~= "table" then return false, "a service must be a table" end
	if type(value.new) ~= "function" then return false, "a service needs new(deps)" end
	if value.needs ~= nil and type(value.needs) ~= "table" then return false, "a service's needs must be a list" end
	if value.handles ~= nil and type(value.handles) ~= "table" then return false, "a service's handles must be a list" end
	return true
end

--- The module a service is built from, with its two per-frame entry points guarded when an outside
--- plugin owns it. The guard goes on the instance after it is made, not on a copy of the module:
--- a service's methods are usually found through the metatable its `new` put on the instance, and
--- a copy would never be called.
---@param self beat.Registry
---@param module beat.Service
---@param plugin beat.Plugin
local function guardService(self, module, plugin)
	if plugin.builtin then return module end
	-- What the collection asks a module for, and nothing else: the plugin's own fields are not
	-- the app's to copy, and the guard is about the calls the plugin wrote.
	---@type beat.Service
	local guarded = { needs = module.needs, handles = module.handles }

	---@param ... any
	---@return beat.ServiceInstance?
	guarded.new = function(...)
		local instance = module.new(...)
		if instance == nil then return nil end

		local step = instance.step or module.step
		if step ~= nil then
			instance.step = function(service, now)
				if plugin.disabled then return nil, false end
				local ok, changed, busy = pcall(step, service, now)
				if not ok then
					self:disable(plugin, changed)
					return nil, false
				end
				return changed, busy
			end
		end

		local update = instance.update or module.update
		if update ~= nil then
			instance.update = function(service, message)
				if plugin.disabled then return end
				local ok, err = pcall(update, service, message)
				if not ok then self:disable(plugin, err) end
			end
		end

		return instance
	end

	return guarded
end

---@param name string
---@param module table
---@param plugin beat.Plugin
---@return fun() undo
function Registry:addService(name, module, plugin)
	namespace(plugin, "service", name)
	local ok, err = serviceShape(module)
	if not ok then error(err, 0) end
	if self.services[name] ~= nil then error("service " .. name .. " is registered twice", 0) end

	local handles = module.handles or {}
	for _, kind in ipairs(handles) do
		if type(kind) ~= "string" then error("a service's handles must be message types", 0) end
		namespace(plugin, "message type", kind)
		if self.handled[kind] ~= nil then error("message type " .. kind .. " is already handled", 0) end
	end

	local registration = { value = guardService(self, module, plugin), plugin = plugin, handles = handles }
	self.services[name] = registration
	for _, kind in ipairs(handles) do self.handled[kind] = registration end

	return function()
		if self.services[name] == registration then self.services[name] = nil end
		for _, kind in ipairs(handles) do
			if self.handled[kind] == registration then self.handled[kind] = nil end
		end
	end
end

---@param kind string
---@param surface beat.PageSurface
---@param plugin beat.Plugin
---@return fun() undo
function Registry:addPage(kind, surface, plugin)
	namespace(plugin, "page", kind)
	local ok, err = pageShape(surface)
	if not ok then error(err, 0) end
	if self.pages[kind] ~= nil then error("page " .. kind .. " is registered twice", 0) end

	local registration = { value = surface, plugin = plugin }
	self.pages[kind] = registration
	return function()
		if self.pages[kind] == registration then self.pages[kind] = nil end
	end
end

---@param name string
---@param surface beat.OverlaySurface
---@param plugin beat.Plugin
---@return fun() undo
function Registry:addOverlay(name, surface, plugin)
	namespace(plugin, "overlay", name)
	local ok, err = overlayShape(surface)
	if not ok then error(err, 0) end
	if self.overlays[name] ~= nil then error("overlay " .. name .. " is registered twice", 0) end

	local registration = { value = surface, plugin = plugin }
	self.overlays[name] = registration
	return function()
		if self.overlays[name] == registration then self.overlays[name] = nil end
	end
end

---@param action beat.Action
---@param plugin beat.Plugin
---@return fun() undo
function Registry:addAction(action, plugin)
	if type(action) ~= "table" then error("an action must be a table", 0) end
	if type(action.menu) ~= "string" then error("an action needs a menu", 0) end
	if type(action.title) ~= "string" then error("an action needs a title", 0) end
	if action.order ~= nil and type(action.order) ~= "number" then error("an action's order must be a number", 0) end
	if action.tone ~= nil and type(action.tone) ~= "string" then error("an action's tone must be a theme colour", 0) end
	if action.when ~= nil and type(action.when) ~= "function" then error("an action's when must be a function", 0) end
	if type(action.message) ~= "table" and type(action.message) ~= "function" then
		error("an action needs a message or a function that makes one", 0)
	end

	local entry = {
		menu = action.menu,
		title = action.title,
		order = action.order or 100,
		tone = action.tone,
		when = action.when,
		message = action.message,
		plugin = plugin,
		index = #self.actionsList + 1
	}
	self.actionsList[#self.actionsList + 1] = entry

	return function()
		for at, candidate in ipairs(self.actionsList) do
			if candidate == entry then
				table.remove(self.actionsList, at)
				return
			end
		end
	end
end

---@param entry beat.NavEntry
---@param plugin beat.Plugin
---@return fun() undo
function Registry:addNav(entry, plugin)
	if type(entry) ~= "table" then error("a nav entry must be a table", 0) end
	if type(entry.id) ~= "string" then error("a nav entry needs an id", 0) end
	if type(entry.title) ~= "string" then error("a nav entry needs a title", 0) end
	if type(entry.icon) ~= "string" then error("a nav entry needs an icon", 0) end
	if type(entry.page) ~= "table" or type(entry.page.kind) ~= "string" then
		error("a nav entry needs a page route", 0)
	end
	if entry.order ~= nil and type(entry.order) ~= "number" then
		error("a nav entry's order must be a number", 0)
	end
	namespace(plugin, "nav", entry.id)

	for _, candidate in ipairs(self.navList) do
		if candidate.id == entry.id then error("nav entry " .. entry.id .. " is registered twice", 0) end
	end

	local registration = {
		id = entry.id,
		title = entry.title,
		icon = entry.icon,
		page = entry.page,
		order = entry.order or 100,
		plugin = plugin,
		index = #self.navList + 1
	}
	self.navList[#self.navList + 1] = registration

	return function()
		for at, candidate in ipairs(self.navList) do
			if candidate == registration then
				table.remove(self.navList, at)
				return
			end
		end
	end
end

---@param kind string
---@param listener fun(message: beat.Message, app: beat.App)
---@param plugin beat.Plugin
---@return fun() undo
function Registry:addListener(kind, listener, plugin)
	if type(listener) ~= "function" then error("on needs a function", 0) end
	local list = self.listeners[kind]
	if list == nil then
		list = {}
		self.listeners[kind] = list
	end
	local entry = { fn = listener, plugin = plugin }
	list[#list + 1] = entry
	return function()
		for at, candidate in ipairs(list) do
			if candidate == entry then
				table.remove(list, at)
				return
			end
		end
	end
end

---@param kind string
---@param interceptor fun(message: beat.Message, app: beat.App, continue: fun(message: beat.Message?))
---@param plugin beat.Plugin
---@return fun() undo
function Registry:addInterceptor(kind, interceptor, plugin)
	if type(interceptor) ~= "function" then error("intercept needs a function", 0) end
	local list = self.interceptors[kind]
	if list == nil then
		list = {}
		self.interceptors[kind] = list
	end
	local entry = { fn = interceptor, plugin = plugin }
	list[#list + 1] = entry
	return function()
		for at, candidate in ipairs(list) do
			if candidate == entry then
				table.remove(list, at)
				return
			end
		end
	end
end

---@param name string
---@return string
---@return string
local function splitName(name)
	local kind, target = name:match("^(%a+):(.+)$")
	local field = kind ~= nil and KINDS[kind] or nil
	if field == nil then error("wrap and replace name a service:, page: or overlay:, not " .. tostring(name), 0) end
	return field, target
end

---@param name string
---@param fn fun(original: any): any
---@param plugin beat.Plugin
---@return fun() undo
function Registry:addWrap(name, fn, plugin)
	if type(fn) ~= "function" then error("wrap needs a function", 0) end
	local field, target = splitName(name)
	if self[field][target] == nil then error("nothing is registered as " .. name, 0) end

	local mod = { kind = "wrap", fn = fn, plugin = plugin }
	local list = self.mods[name]
	if list == nil then
		list = {}
		self.mods[name] = list
	end
	list[#list + 1] = mod

	return function()
		for at, candidate in ipairs(list) do
			if candidate == mod then
				table.remove(list, at)
				return
			end
		end
	end
end

---@param name string
---@param value any
---@param plugin beat.Plugin
---@return fun() undo
function Registry:addReplace(name, value, plugin)
	if value == nil then error("replace needs a value", 0) end
	local field, target = splitName(name)
	if self[field][target] == nil then error("nothing is registered as " .. name, 0) end

	local mod = { kind = "replace", value = value, plugin = plugin }
	local list = self.mods[name]
	if list == nil then
		list = {}
		self.mods[name] = list
	end
	list[#list + 1] = mod

	return function()
		for at, candidate in ipairs(list) do
			if candidate == mod then
				table.remove(list, at)
				return
			end
		end
	end
end

--- One plugin's change to a registered value: a replace ignores what was there, a wrap sees it.
---@param mod beat.Mod
---@param value any
---@param disable fun(plugin: beat.Plugin, reason: any)
---@param name string
local function applyMod(mod, value, disable, name)
	if mod.kind == "replace" then return mod.value end
	if mod.plugin.builtin then return mod.fn(value) end
	local ok, wrapped = pcall(mod.fn, value)
	if not ok then
		disable(mod.plugin, wrapped)
	elseif wrapped == nil then
		disable(mod.plugin, "wrap returned nothing for " .. name)
	else
		return wrapped
	end
	return value
end

---@param self beat.Registry
---@param field string
---@param name string
---@return any
local function resolve(self, field, name)
	local registration = self[field][name]
	if registration == nil then return nil end
	local value = registration.value
	local list = self.mods[field == "services" and ("service:" .. name) or field == "pages" and ("page:" .. name) or ("overlay:" .. name)]
	if list ~= nil then
		for _, mod in ipairs(list) do
			if not mod.plugin.disabled then
				value = applyMod(mod, value, function(plugin, reason) self:disable(plugin, reason) end, name)
			end
		end
	end
	return value
end

---@param kind string
function Registry:page(kind)
	local surface = resolve(self, "pages", kind) --[[@as beat.PageSurface?]]
	if surface == nil then error("no page is registered for " .. tostring(kind), 2) end
	return surface
end

---@param name string
function Registry:overlay(name)
	local surface = resolve(self, "overlays", name) --[[@as beat.OverlaySurface?]]
	if surface == nil then error("no overlay is registered as " .. tostring(name), 2) end
	return surface
end

--- Every service, resolved with the wraps and replacements plugins asked for, ready for
--- `ServiceCollection` to work out the order they are made in.
---@return table<string, beat.Service>
function Registry:serviceModules()
	local services = {}
	for name in pairs(self.services) do services[name] = resolve(self, "services", name) end
	return services
end

--- The entries a menu shows, in order. An entry whose plugin has been switched off, or whose
--- `when` says no, is not there.
---@param menu string
---@param ctx table
---@return { title: string, message: table, tone: string? }[]
function Registry:actions(menu, ctx)
	-- The constructors are the context's, so an action written anywhere can make its message
	-- without the screen that opened the menu having to carry them.
	ctx.message = messages
	local shown = {}
	for _, entry in ipairs(self.actionsList) do
		if entry.menu == menu and not entry.plugin.disabled then
			local visible = true
			if entry.when ~= nil then
				if entry.plugin.builtin then
					visible = entry.when(ctx, self.app) == true
				else
					local ok, result = pcall(entry.when, ctx, self.app)
					if not ok then
						self:disable(entry.plugin, result)
						visible = false
					else
						visible = result == true
					end
				end
			end

			if visible then
				local message = entry.message
				if type(message) == "function" then
					if entry.plugin.builtin then
						message = message(ctx, self.app)
					else
						local ok, result = pcall(message, ctx, self.app)
						if not ok then
							self:disable(entry.plugin, result)
							message = nil
						else
							message = result
						end
					end
				end
				if type(message) == "table" then
					shown[#shown + 1] = { entry = entry, message = message }
				end
			end
		end
	end

	table.sort(shown, function(a, b)
		if a.entry.order ~= b.entry.order then return a.entry.order < b.entry.order end
		return a.entry.index < b.entry.index
	end)

	local actions = {}
	for at, item in ipairs(shown) do
		actions[at] = { title = item.entry.title, message = item.message, tone = item.entry.tone }
	end
	return actions
end

--- The destinations a sidebar shows after the built-in ones, in the order they asked for. An
--- entry whose plugin has been switched off is not there.
---@return beat.NavEntry[]
function Registry:nav()
	local entries = {}
	for _, entry in ipairs(self.navList) do
		if not entry.plugin.disabled then entries[#entries + 1] = entry end
	end
	table.sort(entries, function(a, b)
		if a.order ~= b.order then return a.order < b.order end
		return a.index < b.index
	end)
	return entries
end

--- Runs the interceptors for a message before it is delivered. `continue` is how one passes the
--- message on, possibly changed; not calling it cancels the message for everything below.
---@param message beat.Message
---@param app beat.App
---@return boolean proceed
---@return beat.Message message
function Registry:intercept(message, app)
	local list = self.interceptors[message.type]
	if list == nil then return true, message end

	---@param at number
	---@param current beat.Message
	---@return boolean proceed
	---@return beat.Message message
	local function run(at, current)
		while at <= #list do
			local entry = list[at]
			if entry.plugin.disabled then
				at += 1
			else
				local proceeded, result, delivered = false, true, current
				---@param next beat.Message?
				---@return boolean proceed
				---@return beat.Message message
				local function proceed(next)
					if proceeded then return result end
					proceeded = true
					result, delivered = run(at + 1, next or current)
					return result
				end

				if entry.plugin.builtin then
					entry.fn(current, app, proceed)
				else
					local ok, err = pcall(entry.fn, current, app, proceed)
					if not ok then
						self:disable(entry.plugin, err)
						if not proceeded then
							proceeded = true
							result, delivered = run(at + 1, current)
						end
					end
				end

				if not proceeded then return false, current end
				return result, delivered
			end
		end
		return true, current
	end

	return run(1, message)
end

--- Calls the listeners for a message after it has been delivered.
---@param message beat.Message
---@param app beat.App
function Registry:notify(message, app)
	local list = self.listeners[message.type]
	if list == nil then return end
	for _, entry in ipairs(list) do
		if not entry.plugin.disabled then
			if entry.plugin.builtin then
				entry.fn(message, app)
			else
				local ok, err = pcall(entry.fn, message, app)
				if not ok then self:disable(entry.plugin, err) end
			end
		end
	end
end

return Registry
