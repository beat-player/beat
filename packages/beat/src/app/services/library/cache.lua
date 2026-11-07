-- The last scanned library, kept so a launch can draw the songs it already knows before (or
-- instead of) walking the folder again. Only the fields a Track is made from are written: a scan
-- can rebuild every index and album from them, and a picture is still read from the file itself
-- when a cover is first requested.
local fs = require("fs")
local json = require("json")
local path = require("path")
local paths = require("beat.paths")
local Library = require("beat.music.library")
local Log = require("beat.log")

local LibraryCache = {}

local VERSION = 4

---@return string
local function cacheFile()
	return paths.file("library.json")
end

---@param track beat.Track
---@param key string? # The album the scan put it in, which its tags alone do not always say
---@return table
local function packed(track, key)
	return {
	path = track.path,
	key = key,
	title = track.title,
	artist = track.artist,
	album = track.album,
	albumArtist = track.albumArtist,
	number = track.number,
	disc = track.disc,
	year = track.year,
	genre = track.genre,
	duration = track.duration,
	format = track.format,
	sampleRate = track.sampleRate,
	channels = track.channels,
	hasPicture = track.hasPicture,
	coverPath = track.coverPath,
	coverCache = track.coverCache,
	modified = track.modified,
	}
end

---@param library beat.Library
---@return boolean
---@return string? err
function LibraryCache.save(library)
	local tracks = {}
	for _, track in ipairs(library.tracks) do
		local album = library:album(track.albumId)
		tracks[#tracks + 1] = packed(track, album ~= nil and album.key or nil)
	end

	local ok, encoded = pcall(json.encode, {
	version = VERSION,
	root = library.root,
	tracks = tracks,
	})
	if not ok then return false, tostring(encoded) end

	local folder = paths.directory()
	if not fs.isdir(folder) then
		fs.mkdirAll(folder)
		if not fs.isdir(folder) then return false, "cannot create " .. folder end
	end

	if not fs.write(cacheFile(), encoded) then
		Log.write("error", "library cache could not be written to " .. cacheFile())
		return false
	end

	return true
end

---@param root string
---@return beat.Library?
function LibraryCache.load(root)
	local bytes = fs.read(cacheFile())
	if bytes == nil then return nil end

	local ok, decoded = pcall(function() return json.decode(bytes):unpack() end)

	if not ok then
		Log.write("error", "library cache could not be read: " .. tostring(decoded))
		return nil
	end

	if type(decoded) ~= "table" or decoded.version ~= VERSION or decoded.root ~= root
	or type(decoded.tracks) ~= "table" then
		return nil
	end

	local library = Library.new(root)
	for _, item in ipairs(decoded.tracks) do
			if type(item) ~= "table" or type(item.path) ~= "string" then return nil end

			local dir = path.dirname(item.path)
			local name = path.basename(item.path)
			local ext = name:match("%.([^%.]+)$") or ""
			local info = {
			format = item.format or "unknown",
			sampleRate = item.sampleRate or 0,
			channels = item.channels or 0,
			duration = item.duration or 0,
			hasPicture = item.hasPicture == true,
			tags = {
			title = item.title,
			artist = item.artist,
			album = item.album,
			albumArtist = item.albumArtist,
			track = item.number,
			disc = item.disc,
			date = item.year and tostring(item.year) or nil,
			genre = item.genre,
			},
			}
			library:add(info, {
			path = item.path,
			dir = dir,
			name = name,
			ext = ext,
			modifyTime = item.modified,
			key = type(item.key) == "string" and item.key or nil,
			}, item.coverPath, item.coverCache)
		end
	library:finish()

	return library
end

return LibraryCache
