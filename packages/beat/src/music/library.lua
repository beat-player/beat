-- The library in memory: tracks, the albums they make, and the artists those albums make.
--
-- Nothing here is persisted. A scan fills this from the filesystem, a second scan replaces it,
-- and the process ending is what forgets it. The indexes exist so a screen can ask for an album
-- by id without walking the list, not so a later launch can skip the walk.
local path = require("path")
local names = require("beat.music.names")

---@class beat.Track
---@field id number
---@field path string
---@field title string
---@field artist string
---@field album string
---@field albumId number
---@field artistId number
---@field albumArtist string
---@field disc number
---@field number number?
---@field year number?
---@field genre string?
---@field duration number
---@field format string
---@field sampleRate number
---@field channels number
---@field hasPicture boolean
---@field coverPath string? # A picture beside the tracks, when the file holds none
---@field coverCache string? # The local downscaled copy the scan worker made
---@field modified number # The file's last modification time, in seconds
---@field hash string

---@class beat.Album
---@field id number
---@field key string
---@field title string
---@field artist string
---@field artistId number
---@field year number?
---@field tracks beat.Track[]
---@field duration number
---@field trackCount number
---@field coverPath string?
---@field coverCache string?
---@field coverTrack beat.Track?
---@field modified number # The newest file in the album, in seconds
---@field hash string

---@class beat.Artist
---@field id number
---@field name string
---@field albums beat.Album[]
---@field tracks beat.Track[]
---@field hash string

---@class beat.Library
---@field root string
---@field tracks beat.Track[]
---@field albums beat.Album[]
---@field artists beat.Artist[]
---@field recent beat.Album[] # The albums in the order the scan found them
---@field albumById table<number, beat.Album>
---@field artistById table<number, beat.Artist>
---@field trackById table<number, beat.Track>
---@field albumByKey table<string, beat.Album>
---@field artistByName table<string, beat.Artist>
---@field strings table<string, string> # Repeated tag values, one copy each
---@field version number
---@field ready boolean
local Library = {}
Library.__index = Library

---@param root string
---@return beat.Library
function Library.new(root)
	return setmetatable({
	root = root,
	tracks = {},
	albums = {},
	artists = {},
	recent = {},
	albumById = {},
	artistById = {},
	trackById = {},
	albumByKey = {},
	artistByName = {},
	strings = {},
	version = 0,
	ready = false,
	-- Ids are handed out from counters rather than from the list length: removing the tracks of
	-- a folder leaves gaps, and a later add must not reuse an id something still refers to.
	nextTrackId = 1,
	nextAlbumId = 1,
	nextArtistId = 1,
	}, Library)
end

---@param value string?
local function hasText(value)
	return value ~= nil and value ~= ""
end

--- One copy of a tag value that many tracks share. Titles and paths are mostly unique and are
--- left alone; artists, albums, formats, genres, folders and cover paths repeat by the thousand,
--- and a JSON event decodes its own copy of each.
---@param self beat.Library
---@param value string?
---@return string?
local function intern(self, value)
	if value == nil then return nil end

	local known = self.strings[value]
	if known ~= nil then return known end

	self.strings[value] = value
	return value
end

--- Adds one inspected file. `entry` is what the scanner found; `cover` is the folder picture, if
--- one was beside the file.
---@param info treble.audio.Inspect
---@param entry { path: string, dir: string, name: string, ext: string, modifyTime: number?, key: string? }
---@param cover string?
---@param coverCache string?
---@return beat.Track
---@return boolean gainedCover # Whether this was the album's first cached cover
function Library:add(info, entry, cover, coverCache)
	local tags = info.tags or {}
	local base = names.stripExtension(entry.name)
	local title = hasText(tags.title) and tags.title or names.stripTrackPrefix(base)
	local albumFallback = names.parentName(entry.dir)
	local artistFallback = names.parentName(path.dirname(entry.dir))
	if artistFallback == "Unknown Album" then artistFallback = "Unknown Artist" end

	local artist = intern(self, hasText(tags.artist) and tags.artist or artistFallback) or ""
	local albumTitle = intern(self, hasText(tags.album) and tags.album or albumFallback) or ""
	local albumArtist = intern(self, hasText(tags.albumArtist) and tags.albumArtist or artist) or ""

	local number = tags.track
	if number == nil then
		number = tonumber(entry.name:match("^%s*(%d+)"))
	end

	local date = tags.date
	local disc = tags.disc or 1
	local id = self.nextTrackId
	self.nextTrackId = id + 1
	local duration = info.duration or 0

	---@type beat.Track
	local track = {
	id = id,
	path = entry.path,
	title = title,
	artist = artist,
	album = albumTitle,
	albumId = 0,
	artistId = 0,
	albumArtist = albumArtist,
	disc = disc,
	number = number,
	year = names.yearOf(date),
	genre = intern(self, tags.genre),
	duration = duration,
	format = intern(self, info.format) or "",
	sampleRate = info.sampleRate,
	channels = info.channels,
	hasPicture = info.hasPicture,
	coverPath = intern(self, cover),
	coverCache = intern(self, coverCache),
	modified = entry.modifyTime or 0,
	hash = names.fold(title .. "\0" .. artist .. "\0" .. albumTitle),
	}

	-- The album key is the album artist when the files agree on one, and the album's directory
	-- when they do not: a folder of tracks by different artists is still one compilation. A scan
	-- that already decided which album a file belongs to hands that key over: what a file was
	-- grouped into is not always something its own tags say twice, and a cache replaying the tags
	-- alone would group it again into an album of its own.
	local key = entry.key or names.albumKey(tags, entry.dir)

	local album = self.albumByKey[key]
	local gainedCover = false
	if album == nil then
		local albumId = self.nextAlbumId
		self.nextAlbumId = albumId + 1
		album = {
		id = albumId,
		key = key,
		title = albumTitle,
		artist = albumArtist,
		year = track.year,
		tracks = {},
		duration = 0,
		trackCount = 0,
		coverPath = intern(self, cover),
		coverCache = intern(self, coverCache),
		coverTrack = info.hasPicture and track or nil,
		modified = track.modified,
		hash = names.fold(albumTitle .. "\0" .. albumArtist),
		}

		self.albums[#self.albums + 1] = album
		self.albumById[albumId] = album
		self.albumByKey[key] = album
		self.recent[#self.recent + 1] = album
		if album.coverCache ~= nil then gainedCover = true end
	else
		if album.coverPath == nil then album.coverPath = cover end
		if album.coverCache == nil then
			album.coverCache = intern(self, coverCache)
			if album.coverCache ~= nil then gainedCover = true end
		end
		if album.coverTrack == nil and info.hasPicture then album.coverTrack = track end
		if album.year == nil then album.year = track.year end
		if track.modified > album.modified then album.modified = track.modified end
	end

	album.tracks[#album.tracks + 1] = track
	track.albumId = album.id
	album.trackCount = album.trackCount + 1
	album.duration = album.duration + duration

	local artistKey = albumArtist
	local profile = self.artistByName[artistKey]
	if profile == nil then
		local artistId = self.nextArtistId
		self.nextArtistId = artistId + 1
		profile = {
		id = artistId,
		name = artistKey,
		albums = {},
		tracks = {},
		hash = names.fold(artistKey),
		}

		self.artists[#self.artists + 1] = profile
		self.artistById[artistId] = profile
		self.artistByName[artistKey] = profile
	end

	profile.tracks[#profile.tracks + 1] = track
	track.artistId = profile.id
	album.artistId = profile.id
	if not profile.albums[album.id] then
		profile.albums[album.id] = album
	end

	self.tracks[#self.tracks + 1] = track
	self.trackById[id] = track
	self.version = self.version + 1

	return track, gainedCover
end

--- Whether a track's file is inside a folder. Paths from the scan and from a plugin's dialog can
--- differ in separators or, on Windows, in case, so both sides are normalized first.
---@param base string # The folder, normalized and folded
---@param prefix string # `base` with its trailing separator
---@param fold boolean
---@param file string
---@return boolean
local function under(base, prefix, fold, file)
	local target = path.normalize(file)
	if fold then target = target:lower() end
	return target == base or target:sub(1, #prefix) == prefix
end

--- Drops every track under a folder, and the albums and artists that only those tracks made. A
--- folder added again is then replaced rather than duplicated. The ids are not reused; a queue or
--- a page that still holds an old track keeps a stable number.
---@param folder string
---@return boolean removed # False when the folder held no track, so nothing changed
function Library:removeUnder(folder)
	local fold = path.separator == "\\"
	local base = path.normalize(folder)
	if fold then base = base:lower() end
	local prefix = base:sub(-1) == path.separator and base or base .. path.separator

	local tracks = {}
	local removed = false
	for _, track in ipairs(self.tracks) do
		if under(base, prefix, fold, track.path) then
			self.trackById[track.id] = nil
			removed = true
		else
			tracks[#tracks + 1] = track
		end
	end
	if not removed then return false end
	self.tracks = tracks

	local albums = {}
	for _, album in ipairs(self.albums) do
		local kept = {}
		for _, track in ipairs(album.tracks) do
			if not under(base, prefix, fold, track.path) then kept[#kept + 1] = track end
		end

		if #kept > 0 then
			album.tracks = kept
			album.trackCount = #kept
			album.duration = 0
			for _, track in ipairs(kept) do album.duration = album.duration + track.duration end
			-- Rebuilt by `finish` from what is left, rather than left pointing into the folder
			-- that is gone.
			album.coverTrack = nil
			album.coverPath = nil
			albums[#albums + 1] = album
		else
			self.albumById[album.id] = nil
			self.albumByKey[album.key] = nil
		end
	end
	self.albums = albums

	local recent = {}
	for _, album in ipairs(self.recent) do
		if self.albumById[album.id] ~= nil then recent[#recent + 1] = album end
	end
	self.recent = recent

	local artists = {}
	for _, artist in ipairs(self.artists) do
		local kept = {}
		for _, track in ipairs(artist.tracks) do
			if not under(base, prefix, fold, track.path) then kept[#kept + 1] = track end
		end

		if #kept > 0 then
			artist.tracks = kept
			local albumsOf = {}
			for _, album in ipairs(self.albums) do
				if album.artistId == artist.id then albumsOf[#albumsOf + 1] = album end
			end
			artist.albums = albumsOf
			artists[#artists + 1] = artist
		else
			self.artistById[artist.id] = nil
			self.artistByName[artist.name] = nil
		end
	end
	self.artists = artists

	self.version = self.version + 1
	return true
end

---@param a beat.Track
---@param b beat.Track
local function trackOrder(a, b)
	if a.disc ~= b.disc then return a.disc < b.disc end
	local an, bn = a.number or math.huge, b.number or math.huge
	if an ~= bn then return an < bn end
	if a.title ~= b.title then return names.fold(a.title) < names.fold(b.title) end
	return a.path < b.path
end

---@param a beat.Album
---@param b beat.Album
local function albumOrder(a, b)
	local an, bn = names.fold(a.title), names.fold(b.title)
	if an ~= bn then return an < bn end
	return names.fold(a.artist) < names.fold(b.artist)
end

--- Closes the scan: sorts what was found and computes the values a screen reads in a loop.
function Library:finish()
	for _, album in ipairs(self.albums) do
			table.sort(album.tracks, trackOrder)
			album.trackCount = #album.tracks
			album.duration = 0
			for _, track in ipairs(album.tracks) do
					album.duration = album.duration + track.duration
					if album.coverTrack == nil and track.hasPicture then album.coverTrack = track end
					if album.coverPath == nil then album.coverPath = track.coverPath end
				end
		end

	local orderedAlbums = {}
	for _, album in ipairs(self.albums) do orderedAlbums[#orderedAlbums + 1] = album end
	table.sort(orderedAlbums, albumOrder)
	self.albums = orderedAlbums

	local orderedArtists = {}
	for _, artist in ipairs(self.artists) do
			local albums = {}
			for _, album in pairs(artist.albums) do albums[#albums + 1] = album end
			table.sort(albums, albumOrder)
			artist.albums = albums
			table.sort(artist.tracks, trackOrder)
			orderedArtists[#orderedArtists + 1] = artist
		end
	table.sort(orderedArtists, function(a, b) return a.hash < b.hash end)
	self.artists = orderedArtists

	self.ready = true
	self.version = self.version + 1
end

---@param id number
---@return beat.Album?
function Library:album(id)
	return self.albumById[id]
end

---@param id number
---@return beat.Artist?
function Library:artist(id)
	return self.artistById[id]
end

---@param id number
---@return beat.Track?
function Library:track(id)
	return self.trackById[id]
end

---@param limit number?
---@return beat.Album[]
function Library:recentlyAdded(limit)
	local list = {}
	for index = #self.recent, 1, -1 do
			list[#list + 1] = self.recent[index]
			if limit ~= nil and #list >= limit then break end
		end
	return list
end

---@param query string
---@return beat.Album[] albums, beat.Artist[] artists, beat.Track[] tracks
function Library:search(query)
	local needle = names.fold(query:gsub("^%s+", ""):gsub("%s+$", ""))
	if needle == "" then return {}, {}, {} end

	local albums, artists, tracks = {}, {}, {}

	for _, album in ipairs(self.albums) do
			if album.hash:find(needle, 1, true) then albums[#albums + 1] = album end
		end
	for _, artist in ipairs(self.artists) do
			if artist.hash:find(needle, 1, true) then artists[#artists + 1] = artist end
		end
	for _, track in ipairs(self.tracks) do
			if track.hash:find(needle, 1, true) then tracks[#tracks + 1] = track end
		end

	return albums, artists, tracks
end

return Library
