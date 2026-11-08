-- Tags and playlists are user data, so they live beside settings rather than in the scan cache:
-- they survive a rescan and are keyed by track path, which is the one identity a track keeps.
local fs = require("fs")
local json = require("json")
local paths = require("beat.paths")
local Taxonomy = require("beat.app.services.collections.taxonomy")
local Log = require("beat.log")

local TagStore = {}

local VERSION = 1

---@param dir string?
local function storeFile(dir)
	return paths.file("tags.json", dir)
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

	if type(decoded) ~= "table" or decoded.version ~= VERSION then
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

	local ok, encoded = pcall(json.encode, taxonomy:pack())
	if not ok then
		Log.write("error", "tags could not be encoded: " .. tostring(encoded))
		return false, tostring(encoded)
	end
	if not fs.write(storeFile(folder), encoded) then
		Log.write("error", "tags could not be written to " .. storeFile(folder))
		return false, "cannot write tags.json"
	end
	return true
end

return TagStore
