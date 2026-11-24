-- What a collection on disk says about itself: how a name is folded for comparison, how a file
-- name breaks into a title, and the key an album is grouped by. Nothing here writes for the
-- screen -- a track time or a counted noun belongs to the components. A scan worker loads this
-- file without the app, so it must stay free of anything that draws.
local names = {}

--- A name folded for search. `string.lower` is ASCII-only, which is the right promise: a query
--- keeps its own script, and the Latin part of a title is compared without case.
---@param value string?
function names.fold(value)
	return (value or ""):lower()
end

---@param name string
function names.stripExtension(name)
	return (name:gsub("%.[^%.]+$", ""))
end

--- A file named `01 - Song.flac` is a song called `Song` when nothing wrote a title tag.
---@param name string
function names.stripTrackPrefix(name)
	local stripped = name:gsub("^%s*%d+[%s%-_%.]+", "")

	if stripped == "" then return name end

	return stripped
end

---@param value string?
---@return number?
function names.yearOf(value)
	if value == nil then return nil end
	local year = tonumber(value:match("%d%d%d%d"))

	return year
end

---@param value string?
local function hasText(value)
	return value ~= nil and value ~= ""
end

--- The key a track is filed under while it has no fingerprint: its path, prefixed so it can never
--- be mistaken for a fingerprint.
---@param path string
---@return string
function names.pathKey(path)
	return "path:" .. path
end

-- The key a track without a fingerprint is filed under, made once per track and kept until the
-- library is replaced: it is its path with a prefix, which every screen that rates or filters a
-- row asks for, and building it per row would be a string per row per frame. A track with a
-- fingerprint needs nothing here -- its fingerprint is already the key, and one copy of it is one
-- string the library holds either way. The table holds the tracks weakly so a library replaced by
-- a scan is not kept alive.
---@type table<beat.Track, string>
local pathKeys = setmetatable({}, { __mode = "k" })

--- The key a track's own data is filed under. A fingerprint of the audio survives renaming, moving
--- and retagging, so the listener's tags, rating and plays follow the file; a scan that cannot
--- compute one keeps the path, which is all earlier versions had.
---@param track beat.Track
---@return string
function names.trackKey(track)
	local fingerprint = track.fingerprint
	if fingerprint ~= nil and fingerprint ~= "" then return fingerprint end
	local key = pathKeys[track]
	if key ~= nil then return key end
	key = names.pathKey(track.path)
	pathKeys[track] = key
	return key
end

--- The key a set of tags makes for one album. The scanner's worker and the library both need it,
--- and a cache keyed by one must be the same album the other groups. A file that names no album
--- is a single: its own album of one, keyed by its path, because its tags say nothing that two
--- files with the same title could share. A file that names an album keeps the album artist it
--- groups by, or its folder when it names none.
---@param tags table<string, any>?
---@param dir string
---@param file string # The track's full path, which names a single's album
---@return string
function names.albumKey(tags, dir, file)
	tags = tags or {}
	---@type string?
	local album = type(tags.album) == "string" and tags.album or nil
	---@type string?
	local albumArtist = type(tags.albumArtist) == "string" and tags.albumArtist or nil

	if not hasText(album) then return "single\0" .. file end

	local albumTitle = album
	if hasText(albumArtist) then return albumArtist .. "\0" .. albumTitle end

	return albumTitle .. "\0" .. dir
end

--- Whether an album key names a single: a file with no album tag, whose album is the file itself.
---@param key string
---@return boolean
function names.isSingleKey(key)
	return key:sub(1, 7) == "single\0"
end

return names
