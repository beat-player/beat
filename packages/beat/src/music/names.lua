-- What a collection on disk says about itself: how a name is folded for comparison, how a file
-- name breaks into a title, and the key an album is grouped by. Nothing here writes for the
-- screen -- a track time or a counted noun belongs to the components. A scan worker loads this
-- file without the app, so it must stay free of anything that draws.
local path = require("path")

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

---@param value string
---@return string
function names.parentName(value)
	local name = path.basename(value)

	if name == "" or name == "." or name == path.separator then return "Unknown Album" end

	return name
end

---@param value string?
local function hasText(value)
	return value ~= nil and value ~= ""
end

--- The key a set of tags and a folder make for one album. The scanner's worker and the library
--- both need it, and a cache keyed by one must be the same album the other groups.
---@param tags table<string, any>?
---@param dir string
---@return string
function names.albumKey(tags, dir)
	tags = tags or {}
	---@type string?
	local album = type(tags.album) == "string" and tags.album or nil
	---@type string?
	local albumArtist = type(tags.albumArtist) == "string" and tags.albumArtist or nil
	local albumTitle = hasText(album) and album or names.parentName(dir)

	if hasText(albumArtist) then return albumArtist .. "\0" .. albumTitle end

	return albumTitle .. "\0" .. dir
end

return names
