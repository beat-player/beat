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

--- A page of the app, found by its route kind rather than by a module name.
---@class beat.PageInstance
---@field kind string
---@field id number?
---@field category string?
---@field state table # What the page keeps while it is showing and while it waits in the history

---@class beat.PageSurface
---@field key (fun(page: beat.PageInstance): string)? # Which page this is, for scroll and for not navigating to itself; the kind when absent
---@field new (fun(app: beat.App, page: beat.PageInstance): table)? # The state a page starts with
---@field update (fun(app: beat.App, page: beat.PageInstance, message: table): boolean?)? # True when the message was this page's
---@field leave (fun(app: beat.App, page: beat.PageInstance))? # What the page drops when it is left
---@field view fun(app: beat.App, page: beat.PageInstance, window: wonderland.RenderWindow): wonderland.Element

--- An overlay on the stack above the page.
---@class beat.OverlayInstance
---@field name string
---@field state table

---@class beat.OverlaySurface
---@field light boolean? # Closes on any message it does not handle itself: menus and popovers. A dialog is not light.
---@field anchored boolean? # Drawn by the screen that opened it, at the button that opened it, rather than by the shell
---@field fullscreen boolean? # Is the screen while it is open: the page and the shell around it are not drawn
---@field new fun(app: beat.App, params: table): table? # The overlay's state, or nil to refuse to open
---@field update (fun(app: beat.App, overlay: beat.OverlayInstance, message: table): boolean?)? # True when the message was this overlay's
---@field view (fun(app: beat.App, overlay: beat.OverlayInstance, window: wonderland.RenderWindow): wonderland.Element?)?
---@field close (fun(app: beat.App, overlay: beat.OverlayInstance))? # What closing it undoes: a focused field, a draft

--- One entry of a context menu. The message may be made when the menu opens, so it can name the
--- album or track the menu is for.
---@class beat.Action
---@field menu string
---@field title string
---@field order number?
---@field tone string? # A colour name from the theme; `danger` is the one built-in menus use
---@field when (fun(ctx: table, app: beat.App): boolean?)?
---@field message table|fun(ctx: table, app: beat.App): table?

--- A plugin while it is loaded. Built-in plugins are not protected: their mistakes are the app's.
---@class beat.Plugin
---@field name string
---@field version string
---@field builtin boolean
---@field disabled boolean

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
---@field mods table<string, table[]> # By `page:home`, `overlay:queue`, `service:playback`
---@field handled table<string, beat.Registration> # The service that answers each message type
---@field actionsList table[] # In registration order; sorted when a menu asks
---@field listeners table<string, table[]>
---@field interceptors table<string, table[]>
---@field reports string[] # Problems found before the toasts service could be told
---@field toasts table?
local Registry = {}
Registry.__index = Registry

local KINDS = { service = "services", page = "pages", overlay = "overlays" }

---@param app beat.App
---@return beat.Registry
function Registry.new(app)
	return setmetatable({
		app = app,
		plugins = {},
		services = {},
		pages = {},
		overlays = {},
		mods = {},
		handled = {},
		actionsList = {},
		listeners = {},
		interceptors = {},
		reports = {},
		toasts = nil,
	}, Registry)
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
---@param services table<string, table>
function Registry:attach(services)
	self.toasts = services.toasts
	local reports = self.reports
	self.reports = {}
	for _, text in ipairs(reports) do
		if self.toasts ~= nil then self.toasts:show(text, "error") else Log.write("error", text) end
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
---@param module table
---@param plugin beat.Plugin
---@return table
local function guardService(self, module, plugin)
	if plugin.builtin then return module end
	local guarded = {}
	for key, value in pairs(module) do guarded[key] = value end

	guarded.new = function(deps)
		local instance = module.new(deps)
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

	local registration = { value = guardService(self, module, plugin), plugin = plugin, handles = handles}
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

	local registration = { value = surface, plugin = plugin}
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

	local registration = { value = surface, plugin = plugin}
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
		index = #self.actionsList + 1,
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

---@param kind string
---@param listener fun(message: table, app: beat.App)
---@param plugin beat.Plugin
---@return fun() undo
function Registry:addListener(kind, listener, plugin)
	if type(listener) ~= "function" then error("on needs a function", 0) end
	local list = self.listeners[kind]
	if list == nil then
		list = {}
		self.listeners[kind] = list
	end
	local entry = { fn = listener, plugin = plugin}
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
---@param interceptor fun(message: table, app: beat.App, continue: fun(message: table?))
---@param plugin beat.Plugin
---@return fun() undo
function Registry:addInterceptor(kind, interceptor, plugin)
	if type(interceptor) ~= "function" then error("intercept needs a function", 0) end
	local list = self.interceptors[kind]
	if list == nil then
		list = {}
		self.interceptors[kind] = list
	end
	local entry = { fn = interceptor, plugin = plugin}
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

	local mod = { kind = "wrap", fn = fn, plugin = plugin}
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

	local mod = { kind = "replace", value = value, plugin = plugin}
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

---@param field string
---@param name string
---@return any
local function resolve(self, field, name)
	local registration = self[field][name]
	if registration == nil then return nil end
	local value = registration.value
	local list = self.mods[field == "services" and ("service:" .. name)
		or field == "pages" and ("page:" .. name)
		or ("overlay:" .. name)]
	if list ~= nil then
		for _, mod in ipairs(list) do
			if not mod.plugin.disabled then
				if mod.kind == "replace" then
					value = mod.value
				elseif mod.plugin.builtin then
					value = mod.fn(value)
				else
					local ok, wrapped = pcall(mod.fn, value)
					if not ok then
						self:disable(mod.plugin, wrapped)
					elseif wrapped == nil then
						self:disable(mod.plugin, "wrap returned nothing for " .. name)
					else
						value = wrapped
					end
				end
			end
		end
	end
	return value
end

---@param kind string
---@return beat.PageSurface
function Registry:page(kind)
	local surface = resolve(self, "pages", kind)
	if surface == nil then error("no page is registered for " .. tostring(kind), 2) end
	return surface
end

---@param name string
---@return beat.OverlaySurface
function Registry:overlay(name)
	local surface = resolve(self, "overlays", name)
	if surface == nil then error("no overlay is registered as " .. tostring(name), 2) end
	return surface
end

--- Every service, resolved with the wraps and replacements plugins asked for, ready for
--- `ServiceCollection` to work out the order they are made in.
---@return table<string, table>
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
					shown[#shown + 1] = { entry = entry, message = message}
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
		actions[at] = { title = item.entry.title, message = item.message, tone = item.entry.tone}
	end
	return actions
end

--- Runs the interceptors for a message before it is delivered. `continue` is how one passes the
--- message on, possibly changed; not calling it cancels the message for everything below.
---@param message table
---@param app beat.App
---@return boolean proceed
---@return table message
function Registry:intercept(message, app)
	local list = self.interceptors[message.type]
	if list == nil then return true, message end

	local function run(at, current)
		while at <= #list do
			local entry = list[at]
			if entry.plugin.disabled then
				at = at + 1
			else
				local proceeded, result, delivered = false, true, current
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
---@param message table
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
