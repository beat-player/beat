-- Folder paths as the in-app browser walks and types them.
--
-- The `path` library keeps a Windows drive root as the bare drive -- "C:\" normalizes to "C:",
-- which Windows reads as the current directory on that drive -- and has nothing above it but ".".
-- The browser needs the root itself, and above a root the list of drives.
local ffi = require("ffi")
local bit = require("bit")
local path = require("path")

local folders = {}

--- Whether there is a list of drives above every root. Elsewhere "/" is the top.
folders.windows = jit.os == "Windows"

if folders.windows then
	ffi.cdef [[unsigned long GetLogicalDrives(void);]]
end

--- A Windows path split into its root -- "C:\" or "\\server\share\" -- and what follows it.
---@param p string # Backslashes only
---@return string? root
---@return string rest
local function windowsRoot(p)
	local unc, uncRest = p:match("^(\\\\[^\\]+\\[^\\]+)(.*)$")
	if unc ~= nil then return unc .. "\\", uncRest end
	local drive, driveRest = p:match("^(%a):(.*)$")
	if drive ~= nil then return drive:upper() .. ":\\", driveRest end
	return nil, p
end

---@param rest string
---@return string[]
local function collapse(rest)
	local parts = {}
	for part in rest:gmatch("[^\\]+") do
			if part == ".." then
				parts[#parts] = nil
			elseif part ~= "." then
				parts[#parts + 1] = part
			end
		end
	return parts
end

--- A typed or joined path made absolute and tidy. Surrounding spaces and the quotes Explorer's
--- "Copy as path" adds are dropped, `~` is the home folder, and a relative path is taken from `base`.
---@param p string
---@param base string # Absolute
---@param home string
---@return string
function folders.normalize(p, base, home)
	p = p:match("^%s*(.-)%s*$"):gsub('^"(.*)"$', "%1")
	if p:sub(1, 1) == "~" then p = home .. p:sub(2) end

	if not folders.windows then
		if p:sub(1, 1) ~= "/" then p = base .. "/" .. p end
		return path.normalize(p)
	end

	p = p:gsub("/", "\\")
	local root, rest = windowsRoot(p)
	if root == nil then
		local baseRoot, baseRest = windowsRoot((base:gsub("/", "\\")))
		root = baseRoot or "C:\\"
		-- "\Music" starts at the root of the current drive; "Music" inside the current folder.
		rest = p:sub(1, 1) == "\\" and p or (baseRest .. "\\" .. p)
	end
	return root .. table.concat(collapse(rest), "\\")
end

--- The folder above, or nil at a root: "/", a drive, or a network share.
---@param p string # Normalized
---@return string?
function folders.parent(p)
	if not folders.windows then
		if p == "/" then return nil end
		return path.dirname(p)
	end

	local root, rest = windowsRoot(p)
	local parts = collapse(rest)
	if root == nil or #parts == 0 then return nil end
	parts[#parts] = nil
	return root .. table.concat(parts, "\\")
end

---@param dir string # Normalized
---@param name string
---@return string
function folders.join(dir, name)
	local separator = folders.windows and "\\" or "/"
	if dir:sub(-1) == separator then return dir .. name end
	return dir .. separator .. name
end

--- The drive roots Windows has mounted, in letter order; nothing elsewhere.
---@return string[]
function folders.drives()
	local drives = {}
	if not folders.windows then return drives end
	local mask = tonumber(ffi.C.GetLogicalDrives())
	for at = 0, 25 do
			if bit.band(mask, bit.lshift(1, at)) ~= 0 then
				drives[#drives + 1] = string.char(65 + at) .. ":\\"
			end
		end
	return drives
end

return folders
