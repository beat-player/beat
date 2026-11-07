-- Opening a URL in whatever browser the desktop uses. The commands are the same ones the Last.fm
-- authorization page uses; only http(s) is accepted so a message cannot reach a shell otherwise.
local links = {}

---@param value string
---@return string
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

	return os.execute("(xdg-open " .. target .. " >/dev/null 2>&1 || gio open " .. target
	.. " >/dev/null 2>&1 || sensible-browser " .. target .. " >/dev/null 2>&1) &") == 0
end

return links
