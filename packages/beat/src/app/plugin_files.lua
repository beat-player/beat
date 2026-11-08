-- Finds the plugin bundles in the config directory's `plugins` folder and runs one.
--
-- A bundle is a single Lua file made with `lde bundle`: it puts every module of the plugin
-- package, and of its dependencies, into `package.preload`, then ends by calling the loader of
-- its entry module and returning the plugin table. Running it is how a plugin is read.
--
-- The bundle must not take over a module beat already has. A bundle carries copies of everything
-- it was built against -- wonderland, json, winit -- and those copies are older or simply
-- different from the ones the running app was compiled with. Before the file runs, the global
-- `package` is replaced with a stand-in whose `preload` refuses such names; only the plugin's own
-- modules reach the real `package.preload`, and only when no plugin has already put a module
-- there. The real table comes back when the file is done, however it ends.
--
-- How the host's modules are known depends on how beat is running. Under `lde run` they are files
-- on `package.path` and `package.cpath` (target/ holds beat and every dependency), so a name that
-- resolves there is the host's. In an `lde compile` binary they are not on disk at all: lde's sea
-- emitter puts every module of the bundle, beat's own and its dependencies', into
-- `package.preload` at startup (see `preloadSetup` in lde's packages/sea/src/emit.lua), so the
-- preload table as it stood when this module was first required is the host's module list. Both
-- tables are read for every name, which covers a source run that also has a few preloaded modules
-- and a compiled binary whose module happened to be loaded already.
local fs = require("fs")
local path = require("path")
local paths = require("beat.paths")

local PluginFiles = {}

--- One file in the plugins folder after it was run. `error` is set when the file could not be
--- loaded or raised; otherwise `module` is what it returned, valid or not.
---@class beat.PluginFile
---@field name string # The file name, and what a file that never became a plugin is called
---@field file string
---@field module any # The plugin table the file returned, when it could be run
---@field error string?
---@field clashes string[]? # Modules another plugin already provided
---@field release fun()? # Undoes the preload entries the file added
---@field disabled boolean? # Switched off in Settings: this file was not run

-- The host's modules as they stood before any plugin file ran. A plugin loaded later cannot add
-- to these, so a name found here is never the plugin's to provide.
local HOST_PRELOAD, HOST_LOADED = {}, {}
for name in pairs(package.preload) do HOST_PRELOAD[name] = true end
for name in pairs(package.loaded) do HOST_LOADED[name] = true end

--- Whether a module template (`target/?.lua`, `target/?/init.lua`, ...) finds this name on disk.
---@param template string
---@param modulePath string
---@return boolean
local function templateFinds(template, modulePath)
	if template:find("?", 1, true) == nil then return false end
	local candidate = template:gsub("%?", function() return modulePath end)
	local file = io.open(candidate, "rb")
	if file == nil then return false end
	file:close()
	return true
end

--- Whether beat, or one of the packages it ships, already provides this module.
---@param name string
---@return boolean
local function hostProvides(name)
	if HOST_PRELOAD[name] or HOST_LOADED[name] then return true end

	local modulePath = name:gsub("%.", "/")
	for template in package.path:gmatch("[^;]+") do
		if templateFinds(template, modulePath) then return true end
	end
	for template in package.cpath:gmatch("[^;]+") do
		if templateFinds(template, modulePath) then return true end
	end
	return false
end

--- Drops the preload entries a file added, for a file that did not become a plugin. A module the
--- plugin already required stays loaded -- Lua has no way back from that -- but nothing new can
--- require the rest of it.
---@param added table<string, function>
local function release(added)
	for name, loader in pairs(added) do
		if package.loaded[name] == nil and package.preload[name] == loader then
			package.preload[name] = nil
		end
	end
end

--- A LuaJIT bytecode bundle only loads under the LuaJIT that wrote it. The first bytes say so
--- before the loader does, which lets the error name the likely cause instead of only quoting it.
---@param file string
---@return boolean
local function isBytecode(file)
	local bytes = fs.read(file)
	return bytes ~= nil and bytes:sub(1, 3) == "\27LJ"
end

--- Runs one bundle with the stand-in package in place.
---@param chunk function
---@param file string
---@return any module
---@return string? error
---@return string[] clashes # Modules another plugin already provided; the first plugin keeps them
---@return fun()? release # Undoes the preload entries this file added
local function runIsolated(chunk, file)
	local real = package
	local before = {}
	for name in pairs(real.preload) do before[name] = true end

	local added = {}
	local clashes = {}
	local preload = setmetatable({}, {
		__index = function(_, name) return real.preload[name] end,
		__newindex = function(_, name, loader)
			if type(name) ~= "string" or added[name] ~= nil then return end
			-- A bundle's copy of something the app already has is dropped, not reported: every
			-- bundle carries one, and an app built from source and a compiled one disagree about
			-- where the copy came from.
			if hostProvides(name) then return end
			if before[name] or real.loaded[name] ~= nil then
				-- Another plugin put its module here first. First one wins, and the person is
				-- told rather than one plugin quietly changing the module another one uses.
				clashes[#clashes + 1] = name
				return
			end
			added[name] = loader
			real.preload[name] = loader
		end,
	})

	-- Only `preload` is the stand-in; everything else, including the `cpath` write a bundle makes
	-- while extracting its native libraries, reaches the real package.
	local standIn = setmetatable({ preload = preload }, {
		__index = real,
		__newindex = function(_, key, value) real[key] = value end,
	})

	local previous = rawget(_G, "package")
	_G.package = standIn
	local ok, result = pcall(chunk)
	_G.package = previous

	if not ok then
		release(added)
		return nil, tostring(result), clashes, nil
	end
	return result, nil, clashes, function() release(added) end
end

--- Loads and runs one plugin file.
---@param file string
---@return beat.PluginFile
local function runFile(file)
	local name = path.basename(file)
	local chunk, loadError = loadfile(file)
	if chunk == nil then
		local reason = tostring(loadError)
		if isBytecode(file) or reason:find("bytecode", 1, true) ~= nil then
			reason = reason
				.. " (the file is LuaJIT bytecode; build the bundle again under the same LuaJIT, or without --bytecode)"
		end
		return { name = name, file = file, error = reason}
	end

	local module, runError, clashes, undo = runIsolated(chunk, file)
	return {
		name = name,
		file = file,
		module = module,
		error = runError,
		clashes = clashes,
		release = undo,
	}
end

--- Every `*.lua` file directly in the plugins folder, in file-name order so that which plugin
--- provides a duplicated module is the same on every launch. A missing folder is no plugins.
---
--- A file named in `disabled` is returned without being loaded at all: the switch is keyed by file
--- name exactly so that a switched-off bundle cannot run its top level, and so a file that would
--- not load can still be switched off.
---@param dir string? # The plugins folder; the config directory's when absent
---@param disabled string[]? # File names switched off in Settings
---@return beat.PluginFile[]
function PluginFiles.found(dir, disabled)
	local folder = dir or paths.file("plugins")
	local found = {}
	if not fs.isdir(folder) then return found end

	local off = {}
	for _, name in ipairs(disabled or {}) do off[name] = true end

	local names = {}
	for entry in fs.readdir(folder) do
		if entry.name:sub(-4) == ".lua" then
			local file = path.join(folder, entry.name)
			local isFile = entry.type == "file"
				or (entry.type ~= "dir" and fs.isfile(file))
			if isFile then names[#names + 1] = entry.name end
		end
	end
	table.sort(names)

	for _, name in ipairs(names) do
		local file = path.join(folder, name)
		if off[name] then
			found[#found + 1] = { name = name, file = file, disabled = true }
		else
			found[#found + 1] = runFile(file)
		end
	end
	return found
end

return PluginFiles
