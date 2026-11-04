-- Small things the library and the screens agree on: how a duration is written, how a name is
-- folded for comparison, and what a file name says when a tag does not.
local path = require("path")

local util = {}

---@param value number
---@param low number
---@param high number
function util.clamp(value, low, high)
	if value < low then return low end
	if value > high then return high end
	return value
end

--- A name folded for search. `string.lower` is ASCII-only, which is the right promise: a query
--- keeps its own script, and the Latin part of a title is compared without case.
---@param value string?
function util.fold(value)
	return (value or ""):lower()
end

---@param name string
function util.stripExtension(name)
	return (name:gsub("%.[^%.]+$", ""))
end

--- A file named `01 - Song.flac` is a song called `Song` when nothing wrote a title tag.
---@param name string
function util.stripTrackPrefix(name)
	local stripped = name:gsub("^%s*%d+[%s%-_%.]+", "")

	if stripped == "" then return name end

	return stripped
end

---@param value string?
---@return number?
function util.yearOf(value)
	if value == nil then return nil end
	local year = tonumber(value:match("%d%d%d%d"))

	return year
end

---@param seconds number
---@return string
function util.clock(seconds)
	if seconds == nil or seconds <= 0 then return "--:--" end

	local whole = math.floor(seconds + 0.5)
	local minutes = math.floor(whole / 60)
	local rest = whole % 60

	if minutes >= 60 then
		local hours = math.floor(minutes / 60)
		return string.format("%d:%02d:%02d", hours, minutes % 60, rest)
	end

	return string.format("%d:%02d", minutes, rest)
end

---@param seconds number
---@return string
function util.duration(seconds)
	if seconds <= 0 then return "unknown length" end

	local minutes = math.floor(seconds / 60 + 0.5)

	if minutes < 60 then
		return string.format("%d min", math.max(1, minutes))
	end

	local hours = math.floor(minutes / 60)
	local rest = minutes % 60

	if rest == 0 then return string.format("%d hr", hours) end

	return string.format("%d hr %d min", hours, rest)
end

---@param count number
---@param singular string
---@param plural string?
function util.count(count, singular, plural)
	return string.format("%d %s", count, count == 1 and singular or (plural or singular .. "s"))
end

---@param value string
---@return string
function util.parentName(value)
	local name = path.basename(value)

	if name == "" or name == "." or name == path.separator then return "Unknown Album" end

	return name
end

---@param value string?
---@return boolean
local function hasText(value)
	return value ~= nil and value ~= ""
end

--- The key a set of tags and a folder make for one album. The scanner's worker and the library
--- both need it, and a cache keyed by one must be the same album the other groups.
---@param tags table<string, any>?
---@param dir string
---@return string
function util.albumKey(tags, dir)
	tags = tags or {}
	---@type string?
	local album = type(tags.album) == "string" and tags.album or nil
	---@type string?
	local albumArtist = type(tags.albumArtist) == "string" and tags.albumArtist or nil
	local albumTitle = hasText(album) and album or util.parentName(dir)

	if hasText(albumArtist) then return albumArtist .. "\0" .. albumTitle end

	return albumTitle .. "\0" .. dir
end

return util
