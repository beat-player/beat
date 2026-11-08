-- Where listening stopped: the queue as it stood and how far into its track it had got, so a launch
-- carries on from there. It sits beside the tags rather than in the library cache, because a rescan
-- does not end a session; the queue names its tracks by path for the same reason.
local fs = require("fs")
local json = require("json")
local paths = require("beat.paths")
local Log = require("beat.log")

---@class beat.Session
---@field queue table? # A packed `beat.Queue`; nothing when nothing was queued
---@field seconds number # How far into the current track

local Session = {}

local VERSION = 1

---@param dir string?
local function sessionFile(dir)
	return paths.file("session.json", dir)
end

---@param dir string?
---@return beat.Session?
function Session.load(dir)
	local bytes = fs.read(sessionFile(dir))
	if bytes == nil then return nil end

	local ok, decoded = pcall(|| -> json.decode(bytes):unpack())
	if not ok then
		Log.write("error", "the session could not be read: " .. tostring(decoded))
		return nil
	end

	if type(decoded) ~= "table" or decoded.version ~= VERSION then return nil end
	return {
		queue = type(decoded.queue) == "table" and decoded.queue or nil,
		seconds = type(decoded.seconds) == "number" ? math.max(0, decoded.seconds) : 0
	}
end

-- A failure is logged rather than shown: a read-only config directory must not interrupt playback.
---@param session beat.Session
---@param dir string?
---@return boolean
function Session.save(session, dir)
	local folder = dir or paths.directory()
	if not fs.isdir(folder) then
		fs.mkdirAll(folder)
		if not fs.isdir(folder) then
			Log.write("error", "the session could not be saved: cannot create " .. folder)
			return false
		end
	end

	local ok, encoded = pcall(json.encode, { version = VERSION, queue = session.queue, seconds = session.seconds })
	if not ok then
		Log.write("error", "the session could not be encoded: " .. tostring(encoded))
		return false
	end
	if not fs.write(sessionFile(folder), encoded) then
		Log.write("error", "the session could not be written to " .. sessionFile(folder))
		return false
	end
	return true
end

return Session
