-- Opening a URL in whatever browser the desktop uses, or a folder in its file manager. The
-- commands are the same ones the Last.fm authorization page uses; only http(s) is accepted so a
-- message cannot reach a shell otherwise.
local fs = require("fs")

local links = {}

---@param value string
local function quote(value)
	if jit.os == "Windows" then return '"' .. value:gsub('"', '\\"') .. '"' end
	return "'" .. value:gsub("'", "'\\''") .. "'"
end

---@param url string
---@return boolean
function links.open(url)
	if type(url) ~= "string" or not url:match("^https?://") then return false end

	local target = quote(url)
	local osName = jit.os or ""

	if osName == "Windows" then
		return os.execute('start "" ' .. target) ~= nil
	elseif osName == "OSX" then
		return os.execute("open " .. target .. " >/dev/null 2>&1 &") == 0
	end

	return os.execute(
		"(xdg-open " .. target .. " >/dev/null 2>&1 || gio open " .. target .. " >/dev/null 2>&1 || sensible-browser " .. target .. " >/dev/null 2>&1) &"
	) == 0
end

--- Opens a directory in the desktop's file manager. Only a path is accepted, never an arbitrary
--- command, and it must point at a directory so a typo cannot launch something else.
---@param dir string
---@return boolean
function links.openFolder(dir)
	if type(dir) ~= "string" or not fs.isdir(dir) then return false end

	local target = quote(dir)
	local osName = jit.os or ""

	if osName == "Windows" then
		return os.execute("explorer " .. target) ~= nil
	elseif osName == "OSX" then
		return os.execute("open " .. target .. " >/dev/null 2>&1 &") == 0
	end

	return os.execute("(xdg-open " .. target .. " >/dev/null 2>&1 || gio open " .. target .. " >/dev/null 2>&1) &") == 0
end

return links
