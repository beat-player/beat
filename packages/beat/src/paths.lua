-- Where a launch keeps what it remembers: settings, tags, the library cache and the log all sit in
-- one config directory per account. It is machine plumbing, not part of the settings model -- the
-- log and the stores read it without knowing what a setting is.
local path = require("path")

local paths = {}

---@return string
function paths.directory()
	local osName = jit?.os or ""
	local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "."

	if osName == "Windows" then
		return path.join(os.getenv("APPDATA") or home, "beat")
	elseif osName == "OSX" then
		return path.join(home, "Library", "Application Support", "beat")
	end

	return path.join(os.getenv("XDG_CONFIG_HOME") or path.join(home, ".config"), "beat")
end

--- A file in the config directory, or in `dir` when a caller (a test) names one.
---@param name string
---@param dir string?
---@return string
function paths.file(name, dir)
	return path.join(dir or paths.directory(), name)
end

return paths
