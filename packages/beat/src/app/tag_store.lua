-- Tags and playlists are user data, so they live beside settings rather than in the scan cache:
-- they survive a rescan and are keyed by track path, which is the one identity a track keeps.
local fs = require("fs")
local json = require("json")
local path = require("path")
local core = require("beat-core")

local TagStore = {}

local VERSION = 1

---@param dir string?
---@return string
local function storeFile(dir)
	return path.join(dir or core.settings.directory(), "tags.json")
end

---@param dir string?
---@return beat.Taxonomy
function TagStore.load(dir)
	local file = storeFile(dir)
	local bytes = fs.read(file)
	if bytes == nil then return core.Taxonomy.new() end

	local ok, decoded = pcall(function() return json.decode(bytes):unpack() end)
	if not ok or type(decoded) ~= "table" or decoded.version ~= VERSION then
		return core.Taxonomy.new()
	end

	local unpacked, taxonomy = pcall(core.Taxonomy.unpack, decoded)
	if not unpacked then return core.Taxonomy.new() end
	return taxonomy
end

---@param taxonomy beat.Taxonomy
---@param dir string?
---@return boolean
---@return string?
function TagStore.save(taxonomy, dir)
	local folder = dir or core.settings.directory()
	if not fs.isdir(folder) then
		fs.mkdirAll(folder)
		if not fs.isdir(folder) then return false, "cannot create " .. folder end
	end

	local ok, encoded = pcall(json.encode, taxonomy:pack())
	if not ok then return false, tostring(encoded) end
	if not fs.write(storeFile(folder), encoded) then return false, "cannot write tags.json" end
	return true
end

return TagStore
