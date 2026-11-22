-- Loads the plugins that make up the app: beat's own first, in the order they are listed, then the
-- ones an outside caller passed in. A plugin is a table with a name, a version and a `setup` that
-- registers what it adds through the handle it is given. Built-in plugins are part of beat, so a
-- mistake in one stops the app; an outside plugin that does not fit is reported and left out,
-- taking its own registrations with it.

local settingsModel = require("beat.app.services.settings.model")

local Plugins = {}

-- The built-in plugins that only add something a person can do without. Every other built-in is
-- part of how the app is made -- the shell, the settings page or another built-in asks for its
-- services by name -- so it cannot be switched off at the next start. The page draws no switch
-- for those, and a name in `disabledPlugins` is ignored for them.
local OPTIONAL = {
	ratings = true
}

--- Whether a built-in plugin can be switched off.
---@param name string
---@return boolean
function Plugins.isOptional(name)
	return OPTIONAL[name] == true
end

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
---@field author string? # The person or project the plugin declared, when it declared one
---@field description string? # The plugin's own one line about what it adds
---@field builtin boolean
---@field required boolean? # A built-in the app cannot run without; it has no switch
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
	if module.author ~= nil and type(module.author) ~= "string" then
		return false, "plugin " .. module.name .. " has an author that is not a name"
	end
	if module.description ~= nil and type(module.description) ~= "string" then
		return false, "plugin " .. module.name .. " has a description that is not text"
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
	local handle = {}

	---@param callback fun()
	local function record(callback) undo[#undo + 1] = callback end

	---@param name string
	---@param module beat.Service
	function handle.service(name, module) record(registry:addService(name, module, plugin)) end
	---@param definition beat.PluginSettingsDefinition
	function handle.settings(definition) record(registry:addSettings(definition, plugin)) end
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

---@param module table
---@param builtin boolean
---@param entry beat.PluginStatus
---@return beat.PluginStatus
local function withMetadata(module, builtin, entry)
	if module.author ~= nil and module.author ~= "" then entry.author = module.author end
	if module.description ~= nil and module.description ~= "" then entry.description = module.description end
	if builtin then entry.required = not Plugins.isOptional(module.name) end
	return entry
end

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
		entries[#entries + 1] = withMetadata(
			module,
			builtin,
			status(module.name, module.version, source, "doesn't fit", reason, builtin, candidate.file)
		)
		if candidate.release ~= nil then candidate.release() end
		return
	end

	local met, why = requiresMet(module, loaded)
	if not met then
		if builtin then error("beat plugin " .. module.name .. " " .. why, 0) end
		registry:report("Plugin " .. module.name .. " was not loaded: " .. why)
		entries[#entries + 1] = withMetadata(
			module,
			builtin,
			status(module.name, module.version, source, "doesn't fit", why, builtin, candidate.file)
		)
		if candidate.release ~= nil then candidate.release() end
		return
	end

	local plugin = {
		name = module.name,
		version = module.version,
		author = module.author ~= nil and module.author ~= "" and module.author or nil,
		description = module.description ~= nil and module.description ~= "" and module.description or nil,
		builtin = builtin,
		disabled = false,
		source = source,
		file = candidate.file,
		state = "loaded"
	}
	if builtin then plugin.required = not Plugins.isOptional(module.name) end
	local undo = {}
	local handle = handleFor(registry, plugin, undo)
	local setupOk, setupErr = pcall(module.setup, handle)
	if not setupOk then
		for at = #undo, 1, -1 do undo[at]() end
		if builtin then error(setupErr, 0) end
		local reason = tostring(setupErr)
		registry:report("Plugin " .. plugin.name .. " was not loaded: " .. reason)
		entries[#entries + 1] = withMetadata(
			module,
			builtin,
			status(
				plugin.name,
				plugin.version,
				source,
				readsAsClash(setupErr) and "doesn't fit" or "failed",
				reason,
				builtin,
				candidate.file
			)
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
---@param disabled string[]? # Plugin names switched off; read from the settings file when absent
---@return table<string, beat.Plugin>
---@return beat.PluginStatus[]
function Plugins.load(registry, builtins, outside, disabled)
	local loaded = {}
	local entries = {}

	if disabled == nil then disabled = settingsModel.load().disabledPlugins end
	local off = {}
	for _, name in ipairs(disabled or {}) do off[name] = true end

	for _, name in ipairs(builtins) do
		local module = require("beat.plugins." .. name)
		local ok, err = checkModule(module)
		if not ok then error("beat plugin: " .. err, 0) end

		if off[module.name] and Plugins.isOptional(module.name) then
			-- The module has run -- that is how its version and author are known -- but its setup
			-- has not: nothing it would add is in the app.
			entries[#entries + 1] = withMetadata(
				module,
				true,
				status(module.name, module.version, "built-in", "off", "switched off in Settings", true)
			)
		else
			loadOne(registry, { module = module, source = "built-in" }, true, loaded, entries)
		end
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
