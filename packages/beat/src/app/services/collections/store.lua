-- Tags and playlists are user data, so they live beside settings rather than in the scan cache:
-- they survive a rescan and are keyed by a track key -- the audio's fingerprint where the scan
-- has one -- so a move or a rename does not detach them.
local fs = require("fs")
local json = require("json")
local paths = require("beat.paths")
local Taxonomy = require("beat.app.services.collections.taxonomy")
local Log = require("beat.log")

local TagStore = {}

local VERSION = 2

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

---@param taxonomy beat.Taxonomy
---@param dir string?
---@return boolean
---@return string?
function TagStore.save(taxonomy, dir)
	local folder = dir or paths.directory()
	if not fs.isdir(folder) then
		fs.mkdirAll(folder)
		if not fs.isdir(folder) then return false, "cannot create " .. folder end
	end

	local file = storeFile(folder)
	if not keepV1(file, paths.file("tags.v1.json", folder)) then
		Log.write("error", "tags could not be backed up from " .. file)
		return false, "cannot back up tags.json"
	end

	local ok, encoded = pcall(json.encode, taxonomy:pack())
	if not ok then
		Log.write("error", "tags could not be encoded: " .. tostring(encoded))
		return false, tostring(encoded)
	end
	if not fs.write(file, encoded) then
		Log.write("error", "tags could not be written to " .. file)
		return false, "cannot write tags.json"
	end
	return true
end

return TagStore
