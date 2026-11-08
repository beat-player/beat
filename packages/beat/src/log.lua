-- Errors a person needs after the window has closed: one line in the app's config directory, where
-- settings.json and tags.json already live. A log is best-effort -- a machine with a read-only config
-- directory must still draw, so nothing here is allowed to raise.
local fs = require("fs")
local paths = require("beat.paths")

local log = {}

local LIMIT = 1024 * 1024

local function file()
	return paths.file("beat.log")
end

local function rotate()
	local current = file()
	local stat = fs.stat(current)

	if stat == nil or (stat.size or 0) <= LIMIT then return end

	local previous = current .. ".1"

	pcall(fs.delete, previous)
	pcall(fs.move, current, previous)
end

---@param level string
---@param message any
---@return boolean
function log.write(level, message)
	return pcall(function()
		local directory = paths.directory()

		if not fs.isdir(directory) then
			fs.mkdirAll(directory)
		end

		rotate()

		local line = string.format("%s [%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"),
		level, tostring(message))

		local handle = assert(io.open(file(), "a"))
		handle:write(line)
		handle:close()
	end)
end

return log
