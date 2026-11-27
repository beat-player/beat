-- Tags and playlists are user data, so they live beside settings rather than in the scan cache:
-- they survive a rescan and are keyed by a track key -- the audio's fingerprint where the scan
-- has one -- so a move or a rename does not detach them.
local fs = require("fs")
local json = require("json")
local threading = require("threading")
local paths = require("beat.paths")
local Taxonomy = require("beat.app.services.collections.taxonomy")
local Log = require("beat.log")

local TagStore = {}

local VERSION = 2

---@class beat.TagWrite
---@field handle threading.Handle

-- The write still in flight, if any. Tags and playlists are a small document, and a toggle is a
-- human action: one write at a time is all there is, and a new save waits for the previous one
-- rather than letting two write the same file. The wait is a few milliseconds of file write.
---@type beat.TagWrite?
local inFlight = nil

--- Waits for a write still in flight. Not for a frame: a flush, a synchronous save, or a read
--- that must see what the last save wrote are the callers.
function TagStore.flush()
	local write = inFlight
	if write == nil then return end
	inFlight = nil
	pcall(write.handle.join, write.handle)
end

---@param dir string?
local function storeFile(dir)
	return paths.file("tags.json", dir)
end

--- A version-1 file is read rather than dropped: it keyed tracks by path, and `Taxonomy:adopt`
--- moves each entry onto the key of the track at that path as soon as a library holds one.
---@param version any
local function readable(version)
	return version == 1 or version == VERSION
end

--- Before the first version-2 write replaces a version-1 file, a copy is kept beside it. That file
--- is the only record of which path each tag belonged to before adoption, and an existing backup is
--- never touched, so running this again cannot lose the original.
---@param file string
---@param backup string
local function keepV1(file, backup)
	if fs.exists(backup) then return true end
	local bytes = fs.read(file)
	if bytes == nil then return true end

	local ok, decoded = pcall(|| -> json.decode(bytes):unpack())
	if ok and type(decoded) == "table" and decoded.version == 1 then
		return fs.copy(file, backup)
	end
	return true
end

---@param dir string?
---@return beat.Taxonomy
function TagStore.load(dir)
	-- A save just started on a thread has the newest tags: a reader that wants the file's truth
	-- waits for it rather than reading the one it is about to replace.
	TagStore.flush()

	local file = storeFile(dir)
	local bytes = fs.read(file)
	if bytes == nil then return Taxonomy.new() end

	local ok, decoded = pcall(|| -> json.decode(bytes):unpack())

	if not ok then
		Log.write("error", "tags could not be read: " .. tostring(decoded))
		return Taxonomy.new()
	end

	if type(decoded) ~= "table" or not readable(decoded.version) then
		return Taxonomy.new()
	end

	local unpacked, taxonomy = pcall(Taxonomy.unpack, decoded)
	if not unpacked then return Taxonomy.new() end
	return taxonomy
end

--- Makes the folder, keeps the version-1 backup and encodes the taxonomy: the part both the
--- synchronous and threaded writes need. Nothing here touches the tail of the file.
---@param taxonomy beat.Taxonomy
---@param dir string?
---@return string? file
---@return string? encoded
---@return string? err
local function prepare(taxonomy, dir)
	local folder = dir or paths.directory()
	if not fs.isdir(folder) then
		fs.mkdirAll(folder)
		if not fs.isdir(folder) then return nil, nil, "cannot create " .. folder end
	end

	local file = storeFile(folder)
	if not keepV1(file, paths.file("tags.v1.json", folder)) then
		Log.write("error", "tags could not be backed up from " .. file)
		return nil, nil, "cannot back up tags.json"
	end

	local ok, encoded = pcall(json.encode, taxonomy:pack())
	if not ok then
		Log.write("error", "tags could not be encoded: " .. tostring(encoded))
		return nil, nil, tostring(encoded)
	end
	return file, encoded
end

---@param taxonomy beat.Taxonomy
---@param dir string?
---@return boolean
---@return string?
function TagStore.save(taxonomy, dir)
	-- A reader that saves must not race the write a toggle started: the synchronous form waits,
	-- then writes, so what it leaves is the newest document.
	TagStore.flush()

	local file, encoded, err = prepare(taxonomy, dir)
	if file == nil then return false, err end

	if not fs.write(file, encoded) then
		Log.write("error", "tags could not be written to " .. file)
		return false, "cannot write tags.json"
	end
	return true
end

--- Writes the taxonomy on a thread of its own. The document is encoded here, where it is small,
--- but the write and its syscall do not hold the frame that is drawing the check the listener just
--- pressed. A read or a synchronous save waits for it; a process that is leaving flushes it.
---@param taxonomy beat.Taxonomy
---@param dir string?
---@return boolean
---@return string? err
function TagStore.saveAsync(taxonomy, dir)
	local file, encoded, err = prepare(taxonomy, dir)
	if file == nil then return false, err end

	-- One write at a time: the previous one is a small file write, and letting two write the same
	-- path would leave whichever finished last, which is not necessarily the newest.
	TagStore.flush()

	local ok, handle = pcall(threading.spawn, function()
		local write = require("fs").write
		if not write(file, encoded) then
			require("beat.log").write("error", "tags could not be written to " .. file)
		end
	end)
	if not ok then return false, tostring(handle) end

	inFlight = { handle = handle --[[@as threading.Handle]] }
	return true
end

return TagStore
