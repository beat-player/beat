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
---@param queueJson string? # The queue already encoded, so a write that only moves the play head need not encode it again
---@return boolean
function Session.save(session, dir, queueJson)
	local folder = dir or paths.directory()
	if not fs.isdir(folder) then
		fs.mkdirAll(folder)
		if not fs.isdir(folder) then
			Log.write("error", "the session could not be saved: cannot create " .. folder)
			return false
		end
	end

	local ok, encoded
	if queueJson ~= nil then
		-- The queue's part was encoded by `encodeQueue` and is still valid; only the number beside
		-- it moved. The keys and their order are the same as an encode of the whole table would
		-- write, so a session file written this way is read by the same loader.
		encoded = '{"version":' .. tostring(VERSION) .. ',"queue":' .. queueJson .. ',"seconds":' .. tostring(session.seconds) .. '}'
	else
		ok, encoded = pcall(json.encode, { version = VERSION, queue = session.queue, seconds = session.seconds })
		if not ok then
			Log.write("error", "the session could not be encoded: " .. tostring(encoded))
			return false
		end
	end
	if not fs.write(sessionFile(folder), encoded) then
		Log.write("error", "the session could not be written to " .. sessionFile(folder))
		return false
	end
	return true
end

--- Encodes one queue for `save` to put in a session file. The playback service keeps the result
--- while the queue stays the same, so saving only the play head does not encode every track path
--- again.
---@param packed table
---@return string?
function Session.encodeQueue(packed)
	local ok, encoded = pcall(json.encode, packed)
	if not ok then
		Log.write("error", "the session queue could not be encoded: " .. tostring(encoded))
		return nil
	end
	return encoded --[[@as string]]
end

return Session
