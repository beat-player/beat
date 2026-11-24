-- What `src/music/` may load: it is what a music collection is on disk, and the scan's inspector
-- threads and the audio thread read it without ever building a window. Nothing under it may pull
-- in the app or wonderland itself, or a scan would pay for a renderer it cannot draw with. A
-- wonderland module that draws nothing -- its clock -- is a module like any other.
--
-- The guard follows the whole load, not only the module doing the requiring: a scan reaches
-- `beat.log`, and the log must not pull the app back in through a dependency of its own. While any
-- module under this folder is loading, every require below it is judged by the same rule --
-- so the check stays true however deep the chain goes.
local test = require("lde-test")
local fs = require("fs")

local ROOTS = { "music" }
-- Prefixes forbidden with everything under them, and modules forbidden by exact name.
local FORBIDDEN = { "beat.app" }
local FORBIDDEN_EXACT = { wonderland = true }

local REAL_REQUIRE = require

---@param name string
---@return boolean
local function isForbidden(name)
	if FORBIDDEN_EXACT[name] then return true end
	for _, prefix in ipairs(FORBIDDEN) do
		if name == prefix or name:sub(1, #prefix + 1) == prefix .. "." then return true end
	end

	return false
end

---@param source string
---@return boolean
local function loadsWithoutApp(source)
	local normalized = source:gsub("\\", "/")

	for _, root in ipairs(ROOTS) do
		if normalized:find("/beat/" .. root .. "/", 1, true) then return true end
		if normalized:find("src/" .. root .. "/", 1, true) then return true end
	end

	return false
end

-- The music and worker modules whose load is in progress, innermost last.
local LOADING = {}

---@param name string
---@return unknown
local function guardedRequire(name)
	local info = debug.getinfo(2, "S")
	local source = info and info.source or ""
	if source:sub(1, 1) == "@" then source = source:sub(2) end

	-- A module under the two folders is on the stack, or the requiring module is one of them.
	local fromRoot = #LOADING > 0 or loadsWithoutApp(source)
	if fromRoot and isForbidden(name) then
		local owner = #LOADING > 0 and LOADING[#LOADING] or source
		error(owner .. " must load without the app, but requires " .. name, 0)
	end

	local tracked = loadsWithoutApp(source)
	if tracked then LOADING[#LOADING + 1] = source end

	local ok, result = pcall(REAL_REQUIRE, name)

	if tracked then LOADING[#LOADING] = nil end
	if not ok then error(result, 0) end

	return result
end

---@param name string
---@return boolean
---@return string?
local function loadModule(name)
	package.loaded[name] = nil

	local previous = _G.require
	_G.require = guardedRequire
	local ok, err = pcall(REAL_REQUIRE, name)
	_G.require = previous

	return ok, err
end

---@param root string
---@return string[]
local function modules(root)
	local names = {}
	for file in fs.scan("src/" .. root, "**/*.lua") do
		local name = file:gsub("%.lua$", ""):gsub("[/\\]", "."):gsub("%.init$", "")
		names[#names + 1] = "beat." .. root .. "." .. name
	end

	return names
end

test.it("loads every music module without the app or wonderland", function()
	local names = modules("music")
	test.truthy(#names > 0, "the walk found the music modules")

	for _, name in ipairs(names) do
		local ok, err = loadModule(name)
		test.truthy(ok, name .. " loads: " .. tostring(err))
	end
end)

