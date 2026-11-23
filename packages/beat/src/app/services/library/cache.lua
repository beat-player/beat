-- The last scanned library, kept so a launch can draw the songs it already knows before (or
-- instead of) walking the folder again. Only the fields a Track is made from are written: a scan
-- can rebuild every index and album from them, and a picture is still read from the file itself
-- when a cover is first requested.
local fs = require("fs")
local json = require("json")
local paths = require("beat.paths")
local Library = require("beat.music.library")
local Log = require("beat.log")

local LibraryCache = {}

-- Raised when what a scan reads changes, so a cache written by an older scan is read again rather
-- than trusted: 7 files a track with no album tag as a single of its own, where 6 named it after
-- its folder. 6 added each track's audio fingerprint, which the listener's tags are keyed by, and
-- a cache written before it has none, so every track must be read once to get one. 5 was treble's
-- exact length for an MP3 with no length header, where 4 had a guess.
local VERSION = 7

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
		fingerprint = track.fingerprint
	}
end

---@param library beat.Library
---@return boolean
---@return string? err
function LibraryCache.save(library)
	local tracks = {}
	for _, track in ipairs(library.tracks) do
		local album = library:album(track.albumId)
		tracks[#tracks + 1] = packed(track, album?.key)
	end

	local ok, encoded = pcall(json.encode, { version = VERSION, root = library.root, tracks = tracks })
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

--- A field of a decoded value, or nil when the document does not have it. `json.Value:get` raises
--- for a missing key unless it is given a default, and a default of nil means "no default".
local MISSING = {}

---@param value json.Value
---@param key string
---@return any
local function field(value, key)
	local got = value:get(key, MISSING)
	if got == MISSING then return nil end
	---@cast got json.Value
	return got:val()
end

--- The library a decoded cache says, or nothing for one written for another root or version.
---@param decoded json.Value
---@param root string
---@return beat.Library?
local function read(decoded, root)
	if decoded:type() ~= "object" or field(decoded, "version") ~= VERSION or field(decoded, "root") ~= root then
		return nil
	end

	local tracks = decoded:get("tracks", MISSING)
	if tracks == MISSING then return nil end
	---@cast tracks json.Value
	if not (tracks:is("array") or tracks:is("object")) then return nil end

	local library = Library.new(root)
	for _, item in tracks:children() do
		if item == nil or not item:is("object") then return nil end
		local record = item:unpack()
		if type(record.path) ~= "string" then return nil end
		library:addCached(record)
	end
	library:finish()

	return library
end

--- Reads the cache back into a library. The file is parsed by yyjson outside the Lua heap, and
--- each record is unpacked one at a time, so the read never holds a full Lua copy of the
--- decoded document and the library at once, and only the library outlives the read. The parsed
--- document is freed as soon as the records are in: left to its finalizer it is several MiB of
--- the process held until the collector happens to come round to it.
---@param root string
---@return beat.Library?
function LibraryCache.load(root)
	local file = cacheFile()
	if not fs.isfile(file) then return nil end

	local ok, document = pcall(json.Document.open, file)
	if not ok then
		Log.write("error", "library cache could not be read: " .. tostring(document))
		return nil
	end

	---@cast document json.Document
	local library = read(document:root(), root)
	document:free()
	return library
end

return LibraryCache
