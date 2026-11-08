-- Loads the plugins that make up the app: beat's own first, in the order they are listed, then the
-- ones an outside caller passed in. A plugin is a table with a name, a version and a `setup` that
-- registers what it adds through the handle it is given. Built-in plugins are part of beat, so a
-- mistake in one stops the app; an outside plugin that does not fit is reported and left out,
-- taking its own registrations with it.
local Messages = require("beat.message")

local Plugins = {}

---@param text string
local function parseVersion(text)
	local major, minor, patch = text:match("^(%d+)%.(%d+)%.(%d+)$")
	if major ~= nil then return { tonumber(major), tonumber(minor), tonumber(patch) } end
	major, minor = text:match("^(%d+)%.(%d+)$")
	if major ~= nil then return { tonumber(major), tonumber(minor), 0 } end
	major = text:match("^(%d+)$")
	if major ~= nil then return { tonumber(major), 0, 0 } end
	return nil
end

---@param a number[]
---@param b number[]
---@return number
local function compare(a, b)
	for at = 1, 3 do
		if a[at] ~= b[at] then return a[at] < b[at] and -1 or 1 end
	end
	return 0
end

--- What the plugins page shows about a plugin that did not load, or that is switched off. A loaded
--- plugin's own table is the status, so a runtime switch-off is seen without a second record.
---@class beat.PluginStatus
---@field name string
---@field version string?
---@field builtin boolean
---@field disabled boolean # Switched off by the person, or by a hook that raised
---@field source string # "built-in", or the file the plugin came from (or was given by a caller)
---@field file string? # The plugins-folder file, when it came from one; the switch is keyed by its name
---@field state "loaded"|"off"|"failed"|"doesn't fit"|"switched off"
---@field reason string?

---@param name string
---@param version string?
---@param source string
---@param state "loaded"|"off"|"failed"|"doesn't fit"|"switched off"
---@param reason string?
---@param builtin boolean?
---@param file string?
---@return beat.PluginStatus
local function status(name, version, source, state, reason, builtin, file)
	return {
		name = name,
		version = version,
		source = source,
		file = file,
		state = state,
		reason = reason,
		builtin = builtin == true,
		disabled = state == "off" or state == "switched off"
	}
end

--- A setup error that is about the plugin not fitting -- a registration named outside its
--- namespace, a name another plugin already took -- rather than the plugin's own code failing.
---@param value any
local function readsAsClash(value)
	local text = tostring(value)
	return text:find("must be named", 1, true) ~= nil or text:find("registered twice", 1, true) ~= nil or text:find(
		"is already handled",
		1,
		true
	) ~= nil or text:find("nothing is registered as", 1, true) ~= nil
end

--- Whether a version satisfies one requirement. `^1` and `~1` are read as `^1.0.0` and `~1.0.0`:
--- the rest of a version is zero when it is not written.
---@param version string
---@param requirement string
---@return boolean
---@return string? why
local function satisfies(version, requirement)
	local op, rest = requirement:match("^%s*([%^~<>=]*)(.-)%s*$")
	if op == "" then op = "=" end
	if op ~= "=" and op ~= ">=" and op ~= "^" and op ~= "~" then
		return false, "understands ^, ~, >= and exact versions, not " .. requirement
	end

	local want = parseVersion(rest)
	local have = parseVersion(version)
	if want == nil then return false, requirement .. " is not a version" end
	if have == nil then return false, "its own version is not a version" end

	local order = compare(have, want)
	if op == "=" then return order == 0 end
	if op == ">=" then return order >= 0 end
	if order < 0 then return false end

	if op == "^" then
		-- The leftmost non-zero part is the one that may not change.
		if want[1] > 0 then return have[1] == want[1] end
		if want[2] > 0 then return have[1] == 0 and have[2] == want[2] end
		return have[1] == 0 and have[2] == 0 and have[3] == want[3]
	end

	-- `~`: the patch may move, the minor may not.
	return have[1] == want[1] and have[2] == want[2]
end

---@param module any
---@return boolean
---@return string?
local function checkModule(module)
	if type(module) ~= "table" then return false, "a plugin must be a table" end
	if type(module.name) ~= "string" or module.name == "" then return false, "a plugin needs a name" end
	if type(module.version) ~= "string" or module.version:match("^%d+%.%d+%.%d+$") == nil then
		return false, "plugin " .. module.name .. " needs a version like 1.2.3"
	end
	if module.requires ~= nil and type(module.requires) ~= "table" then
		return false, "plugin " .. module.name .. " has requires that are not a table"
	end
	if type(module.setup) ~= "function" then
		return false, "plugin " .. module.name .. " needs setup(beat)"
	end
	return true
end

---@param module table
---@param loaded table<string, beat.Plugin>
---@return boolean
---@return string?
local function requiresMet(module, loaded)
	---@type table<string, string>
	local requires = module.requires or {}
	for name, requirement in pairs(requires) do
		local dependency = loaded[name]
		if dependency == nil then
			return false, "it needs plugin " .. name .. " " .. tostring(requirement) .. ", which is not loaded"
		end
		local met, why = satisfies(dependency.version, requirement)
		if not met then
			return false, "it needs plugin " .. name .. " " .. tostring(requirement) .. ", but " .. dependency.version .. " is loaded" .. (why ~= nil and (": " .. why) or "")
		end
	end
	return true
end

--- What a plugin registers through. Every registration is recorded so a plugin that cannot finish
--- setting up can be taken back out of the app without leaving half of it behind.
---@param registry beat.Registry
---@param plugin beat.Plugin
---@param undo fun()[]
local function handleFor(registry, plugin, undo)
	---@type beat.PluginHandle
	local handle = { msg = Messages }

	---@param callback fun()
	local function record(callback) undo[#undo + 1] = callback end

	---@param name string
	---@param module beat.Service
	function handle.service(name, module) record(registry:addService(name, module, plugin)) end
	---@param kind string
	---@param surface beat.PageSurface
	function handle.page(kind, surface) record(registry:addPage(kind, surface, plugin)) end
	---@param name string
	---@param surface beat.OverlaySurface
	function handle.overlay(name, surface) record(registry:addOverlay(name, surface, plugin)) end
	---@param action beat.Action
	function handle.action(action) record(registry:addAction(action, plugin)) end
	---@param entry beat.NavEntry
	function handle.nav(entry) record(registry:addNav(entry, plugin)) end
	---@param kind string
	---@param listener fun(message: table, app: beat.App)
	function handle.on(kind, listener) record(registry:addListener(kind, listener, plugin)) end
	---@param kind string
	---@param interceptor fun(message: table, app: beat.App, continue: fun(message: table?))
	function handle.intercept(kind, interceptor) record(registry:addInterceptor(kind, interceptor, plugin)) end
	---@param name string
	---@param fn fun(original: any): any
	function handle.wrap(name, fn) record(registry:addWrap(name, fn, plugin)) end
	---@param name string
	---@param value any
	function handle.replace(name, value) record(registry:addReplace(name, value, plugin)) end

	return handle
end

--- One thing eligible to load: a built-in module, a file's result, or a caller's plugin.
---@class beat.PluginCandidate
---@field module any? # The plugin table; nil when the file could not run
---@field source string? # "built-in", or the name a person sees
---@field file string?
---@field name string?
---@field error string?
---@field clashes string[]?
---@field release (fun())?
---@field disabled boolean?

---@param registry beat.Registry
---@param candidate beat.PluginCandidate
---@param builtin boolean
---@param loaded table<string, beat.Plugin>
---@param entries beat.PluginStatus[]
local function loadOne(registry, candidate, builtin, loaded, entries)
	local module = candidate.module
	local source = candidate.source or candidate.file or "given to the app"
	local label = candidate.name or source

	local ok, err = checkModule(module)
	if not ok then
		if builtin then error("beat plugin: " .. err, 0) end
		registry:report("A plugin was not loaded: " .. err)
		entries[#entries + 1] = status(label, nil, source, "failed", err, builtin, candidate.file)
		if candidate.release ~= nil then candidate.release() end
		return
	end

	if loaded[module.name] ~= nil then
		if builtin then error("beat plugin " .. module.name .. " is loaded twice", 0) end
		local reason = "the name is already taken"
		registry:report("Plugin " .. module.name .. " was not loaded: " .. reason)
		entries[#entries + 1] = status(module.name, module.version, source, "doesn't fit", reason, builtin, candidate.file)
		if candidate.release ~= nil then candidate.release() end
		return
	end

	local met, why = requiresMet(module, loaded)
	if not met then
		if builtin then error("beat plugin " .. module.name .. " " .. why, 0) end
		registry:report("Plugin " .. module.name .. " was not loaded: " .. why)
		entries[#entries + 1] = status(module.name, module.version, source, "doesn't fit", why, builtin, candidate.file)
		if candidate.release ~= nil then candidate.release() end
		return
	end

	local plugin = {
		name = module.name,
		version = module.version,
		builtin = builtin,
		disabled = false,
		source = source,
		file = candidate.file,
		state = "loaded"
	}
	local undo = {}
	local handle = handleFor(registry, plugin, undo)
	local setupOk, setupErr = pcall(module.setup, handle)
	if not setupOk then
		for at = #undo, 1, -1 do undo[at]() end
		if builtin then error(setupErr, 0) end
		local reason = tostring(setupErr)
		registry:report("Plugin " .. plugin.name .. " was not loaded: " .. reason)
		entries[#entries + 1] = status(
			plugin.name,
			plugin.version,
			source,
			readsAsClash(setupErr) and "doesn't fit" or "failed",
			reason,
			builtin,
			candidate.file
		)
		if candidate.release ~= nil then candidate.release() end
		return
	end

	loaded[plugin.name] = plugin
	registry.plugins[#registry.plugins + 1] = plugin
	entries[#entries + 1] = plugin
end

--- Loads beat's own plugins, then the outside ones, and returns what loaded by name and one status
--- for every plugin the page can list -- including the ones that are off, failed or did not fit.
---@param registry beat.Registry
---@param builtins string[] # Module names under `beat.plugins`
---@param outside beat.PluginCandidate[]? # `beat.PluginFile`s, or `{ module = plugin }` from a caller
---@return table<string, beat.Plugin>
---@return beat.PluginStatus[]
function Plugins.load(registry, builtins, outside)
	local loaded = {}
	local entries = {}

	for _, name in ipairs(builtins) do
		loadOne(registry, { module = require("beat.plugins." .. name), source = "built-in" }, true, loaded, entries)
	end

	for _, candidate in ipairs(outside or {}) do
		local module = candidate.module
		if candidate.disabled then
			-- The finder did not run this file at all, so there is no name or version to show:
			-- the switch is keyed by the file name and that is what the page lists.
			entries[#entries + 1] = status(
				candidate.name or candidate.file or "a plugin file",
				nil,
				candidate.file or "given to the app",
				"off",
				"switched off in Settings",
				false,
				candidate.file
			)
		elseif module == nil then
			local reason = candidate.error or "the file did not return a plugin"
			registry:report((candidate.name or "a plugin file") .. " was not loaded: " .. reason)
			entries[#entries + 1] = status(
				candidate.name or "a plugin file",
				nil,
				candidate.file or "given to the app",
				"failed",
				reason,
				false,
				candidate.file
			)
			if candidate.release ~= nil then candidate.release() end
		else
			local ok, err = checkModule(module)
			if not ok then
				registry:report((candidate.name or "A plugin") .. " was not loaded: " .. err)
				entries[#entries + 1] = status(
					candidate.name or "A plugin",
					nil,
					candidate.file or "given to the app",
					"failed",
					err,
					false,
					candidate.file
				)
				if candidate.release ~= nil then candidate.release() end
			else
				if candidate.clashes ~= nil and #candidate.clashes > 0 then
					registry:report(
						(candidate.name or module.name) .. " brought modules another plugin already provides, which were not used: " .. table.concat(
							candidate.clashes,
							", "
						)
					)
				end
				loadOne(registry, candidate, false, loaded, entries)
			end
		end
	end

	return loaded, entries
end

return Plugins
