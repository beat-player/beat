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
---@field fingerprint string? # A fingerprint of the audio itself, when the scan can compute one
---@field searchText string? # Folded title, artist and album, made on the first search

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
---@field searchText string? # Folded title and artist, made on the first search

---@class beat.Artist
---@field id number
---@field name string
---@field albums beat.Album[]
---@field tracks beat.Track[]
---@field searchText string? # The folded name, made on the first search

--- What one search answered, kept so a query that only adds characters can look in it instead of
--- the whole library.
---@class beat.SearchSweep
---@field needle string # The folded query this answers
---@field version number # The library version it was computed for
---@field albums beat.Album[]
---@field artists beat.Artist[]
---@field tracks beat.Track[]

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
---@field sweep beat.SearchSweep? # The last search, for a longer query to narrow
---@field nextTrackId number # The id the next track is given; ids are never reused
---@field nextAlbumId number
---@field nextArtistId number
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
		sweep = nil,
		version = 0,
		ready = false,
		-- Ids are handed out from counters rather than from the list length: removing the tracks of
		-- a folder leaves gaps, and a later add must not reuse an id something still refers to.
		nextTrackId = 1,
		nextAlbumId = 1,
		nextArtistId = 1
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
local function intern(self, value)
	if value == nil then return nil end

	local known = self.strings[value]
	if known ~= nil then return known end

	self.strings[value] = value
	return value
end

--- Files one track under its album and artist, and puts it in the indexes. What a track is called
--- is already decided by the caller: `add` from a scan's tags, `addCached` from what a cache wrote
--- down. Both meet here, because an album and an artist are made the same way however the track
--- arrived.
---@param self beat.Library
---@param track beat.Track
---@param key string # The album the scan put it in
---@return beat.Track
---@return boolean gainedCover # Whether this was the album's first cached cover
local function place(self, track, key)
	local album = self.albumByKey[key]
	local gainedCover = false
	if album == nil then
		local albumId = self.nextAlbumId
		self.nextAlbumId = albumId + 1
		album = {
			id = albumId,
			key = key,
			title = track.album,
			artist = track.albumArtist,
			year = track.year,
			tracks = {},
			duration = 0,
			trackCount = 0,
			coverPath = track.coverPath,
			coverCache = track.coverCache,
			coverTrack = track.hasPicture and track or nil,
			modified = track.modified
		}

		self.albums[#self.albums + 1] = album
		self.albumById[albumId] = album
		self.albumByKey[key] = album
		self.recent[#self.recent + 1] = album
		if album.coverCache ~= nil then gainedCover = true end
	else
		if album.coverPath == nil then album.coverPath = track.coverPath end
		if album.coverCache == nil then
			album.coverCache = track.coverCache
			if album.coverCache ~= nil then gainedCover = true end
		end
		if album.coverTrack == nil and track.hasPicture then album.coverTrack = track end
		if album.year == nil then album.year = track.year end
		if track.modified > album.modified then album.modified = track.modified end
	end

	album.tracks[#album.tracks + 1] = track
	track.albumId = album.id
	album.trackCount += 1
	album.duration += track.duration

	local artistKey = track.albumArtist
	local profile = self.artistByName[artistKey]
	if profile == nil then
		local artistId = self.nextArtistId
		self.nextArtistId = artistId + 1
		profile = { id = artistId, name = artistKey, albums = {}, tracks = {} }

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
	self.trackById[track.id] = track
	-- A search answered for the tracks as they were, and a new track can only lengthen that answer.
	self.sweep = nil
	self.version += 1

	return track, gainedCover
end

--- The album key is the album artist when the files agree on one, and the album's directory
--- when they do not: a folder of tracks by different artists is still one compilation. A scan
--- that already decided which album a file belongs to hands that key over: what a file was
--- grouped into is not always something its own tags say twice, and a cache replaying the tags
--- alone would group it again into an album of its own.
---@param tags table<string, any>?
---@param dir string
---@param key string?
---@return string
local function albumKeyOf(tags, dir, key)
	if key ~= nil then return key end
	return names.albumKey(tags, dir)
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

	local id = self.nextTrackId
	self.nextTrackId = id + 1

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
		disc = tags.disc or 1,
		number = number,
		year = names.yearOf(tags.date),
		genre = intern(self, tags.genre),
		duration = info.duration or 0,
		format = intern(self, info.format) or "",
		sampleRate = info.sampleRate,
		channels = info.channels,
		hasPicture = info.hasPicture,
		coverPath = intern(self, cover),
		coverCache = intern(self, coverCache),
		modified = entry.modifyTime or 0,
		fingerprint = info.fingerprint
	}

	return place(self, track, albumKeyOf(tags, entry.dir, entry.key))
end

---@param value any
---@return string?
local function textOf(value)
	if type(value) ~= "string" then return nil end
	return value
end

---@param value any
---@param fallback number?
---@return number?
local function numberOf(value, fallback)
	if type(value) ~= "number" then return fallback end
	return value
end

---@param value any
---@param fallback number
---@return number
local function numberOr(value, fallback)
	if type(value) ~= "number" then return fallback end
	return value
end

--- Adds one track a cache wrote down: the values `add` derives from a scan's tags and folder are
--- already there, so nothing here re-derives a title from a file name or a folder from a path. A
--- launch reads thousands of these before it draws anything, and the tables and the folded strings
--- a derivation would make for each were most of the garbage and a third of the time.
---@param record table # One `packed` record from the cache
---@return beat.Track
---@return boolean gainedCover # Whether this was the album's first cached cover
function Library:addCached(record)
	local file = record.path
	assert(type(file) == "string", "a cached track needs its path")
	local title = textOf(record.title)
	local artist = intern(self, textOf(record.artist)) or ""
	local albumTitle = intern(self, textOf(record.album)) or ""
	local albumArtist = intern(self, textOf(record.albumArtist)) or ""
	local key = textOf(record.key)

	if title == nil or title == "" or artist == "" or albumTitle == "" or albumArtist == "" or key == nil then
		-- A record that does not say everything is filled in the way a scan would fill it in, from
		-- the file's path. What the cache does say is kept; interning a value twice hands back the
		-- copy already in the library.
		local dir = path.dirname(file)
		if title == nil or title == "" then
			title = names.stripTrackPrefix(names.stripExtension(path.basename(file)))
		end
		local albumFallback = names.parentName(dir)
		local artistFallback = names.parentName(path.dirname(dir))
		if artistFallback == "Unknown Album" then artistFallback = "Unknown Artist" end
		if artist == "" then artist = intern(self, artistFallback) or "" end
		if albumTitle == "" then albumTitle = intern(self, albumFallback) or "" end
		if albumArtist == "" then albumArtist = artist end
		if key == nil then
			key = names.albumKey({ album = albumTitle, albumArtist = albumArtist }, dir)
		end
	end

	local id = self.nextTrackId
	self.nextTrackId = id + 1

	---@type beat.Track
	local track = {
		id = id,
		path = file,
		title = title,
		artist = artist,
		album = albumTitle,
		albumId = 0,
		artistId = 0,
		albumArtist = albumArtist,
		disc = numberOr(record.disc, 1),
		number = numberOf(record.number),
		year = numberOf(record.year),
		genre = intern(self, textOf(record.genre)),
		duration = numberOr(record.duration, 0),
		format = intern(self, textOf(record.format)) or "",
		sampleRate = numberOr(record.sampleRate, 0),
		channels = numberOr(record.channels, 0),
		hasPicture = record.hasPicture == true,
		coverPath = intern(self, textOf(record.coverPath)),
		coverCache = intern(self, textOf(record.coverCache)),
		modified = numberOr(record.modified, 0),
		fingerprint = textOf(record.fingerprint)
	}

	---@cast key string
	return place(self, track, key)
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
	-- TODO: This doesn't really make sense to users as we don't normalize
	-- the track number to each disc (so if track 19 is on disc 2, it'll count as #19 instead of #1).
	-- if a.disc ~= b.disc then return a.disc < b.disc end
	local an, bn = a.number or math.huge, b.number or math.huge
	if an ~= bn then return an < bn end
	if a.title ~= b.title then return names.fold(a.title) < names.fold(b.title) end
	return a.path < b.path
end

--- Folded titles and artists, one entry per album, for a sort to compare instead of folding the
--- same two names on every comparison. A comparator is called some thousands of times for the
--- albums of a library, and folding inside it lowers both names each time.
---@param albums beat.Album[]
---@return table<beat.Album, string> titles
---@return table<beat.Album, string> artists
local function foldedAlbums(albums)
	local titles, artists = {}, {}
	for _, album in ipairs(albums) do
		titles[album] = names.fold(album.title)
		artists[album] = names.fold(album.artist)
	end
	return titles, artists
end

--- Closes the scan: sorts what was found and computes the values a screen reads in a loop.
function Library:finish()
	for _, album in ipairs(self.albums) do
		table.sort(album.tracks, trackOrder)
		album.trackCount = #album.tracks
		album.duration = 0
		for _, track in ipairs(album.tracks) do
			album.duration += track.duration
			if album.coverTrack == nil and track.hasPicture then album.coverTrack = track end
			if album.coverPath == nil then album.coverPath = track.coverPath end
		end
	end

	local titles, artists = foldedAlbums(self.albums)
	local function byName(a, b)
		local at, bt = titles[a], titles[b]
		if at ~= bt then return at < bt end
		return artists[a] < artists[b]
	end
	local orderedAlbums = {}
	for _, album in ipairs(self.albums) do orderedAlbums[#orderedAlbums + 1] = album end
	table.sort(orderedAlbums, byName)
	self.albums = orderedAlbums

	local orderedArtists = {}
	for _, artist in ipairs(self.artists) do
		local albums = {}
		for _, album in pairs(artist.albums) do albums[#albums + 1] = album end
		table.sort(albums, byName)
		artist.albums = albums
		table.sort(artist.tracks, trackOrder)
		orderedArtists[#orderedArtists + 1] = artist
	end
	local namesFolded = {}
	for _, artist in ipairs(orderedArtists) do namesFolded[artist] = names.fold(artist.name) end
	table.sort(orderedArtists, |a, b| -> namesFolded[a] < namesFolded[b])
	self.artists = orderedArtists

	self.ready = true
	self.sweep = nil
	self.version += 1
end

---@param id number
---@return beat.Album?
function Library:album(id)
	return self.albumById[id]
end

--- An album by the key the scan files it under. A route written down by a previous launch names
--- an album this way: its id is only the order that launch's scan found it in.
---@param key string
---@return beat.Album?
function Library:findAlbum(key)
	return self.albumByKey[key]
end

---@param id number
---@return beat.Artist?
function Library:artist(id)
	return self.artistById[id]
end

--- An artist by the album artist's name, which is what the library indexes them by and what a
--- saved page keeps instead of the id a scan happened to give them.
---@param name string
---@return beat.Artist?
function Library:findArtist(name)
	return self.artistByName[name]
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

--- The folded text of everything a search looks in, made where it is missing. Only the first
--- search of a library writes them; every later one finds the fields already there. They are kept
--- on the album, artist and track because a title, an artist and an album do not change once the
--- item is in the library, so the text cannot go stale.
---@param self beat.Library
local function prepareSearch(self)
	for _, album in ipairs(self.albums) do
		if album.searchText == nil then
			album.searchText = names.fold(album.title .. "\0" .. album.artist)
		end
	end
	for _, artist in ipairs(self.artists) do
		if artist.searchText == nil then artist.searchText = names.fold(artist.name) end
	end
	for _, track in ipairs(self.tracks) do
		if track.searchText == nil then
			track.searchText = names.fold(track.title .. "\0" .. track.artist .. "\0" .. track.album)
		end
	end
end

--- Every album, artist and track whose text holds `needle`, and the sweep to narrow from if the
--- query grows. The sweep names the library version it answers: a track added or a scan closed
--- makes the previous answer incomplete, and then there is nothing to narrow.
---@param self beat.Library
---@param needle string
---@return beat.SearchSweep
local function sweepLibrary(self, needle)
	prepareSearch(self)
	local albums, artists, tracks = {}, {}, {}
	for _, album in ipairs(self.albums) do
		local text = album.searchText
		if text ~= nil and text:find(needle, 1, true) then albums[#albums + 1] = album end
	end
	for _, artist in ipairs(self.artists) do
		local text = artist.searchText
		if text ~= nil and text:find(needle, 1, true) then artists[#artists + 1] = artist end
	end
	for _, track in ipairs(self.tracks) do
		local text = track.searchText
		if text ~= nil and text:find(needle, 1, true) then tracks[#tracks + 1] = track end
	end
	return { needle = needle, version = self.version, albums = albums, artists = artists, tracks = tracks }
end

---@param query string
---@return beat.Album[] albums, beat.Artist[] artists, beat.Track[] tracks
function Library:search(query)
	local needle = names.fold(query:gsub("^%s+", ""):gsub("%s+$", ""))
	if needle == "" then return {}, {}, {} end

	local known = self.sweep
	if known ~= nil and known.version == self.version then
		if known.needle == needle then return known.albums, known.artists, known.tracks end
		-- A query that only adds characters cannot match anything the shorter one did not: the
		-- text is searched for a substring, and the longer needle holds the shorter one. So a
		-- keystroke looks in what the last one answered rather than in the whole library.
		if needle:sub(1, #known.needle) == known.needle then
			local albums, artists, tracks = {}, {}, {}
			for _, album in ipairs(known.albums) do
				local text = album.searchText
				if text ~= nil and text:find(needle, 1, true) then albums[#albums + 1] = album end
			end
			for _, artist in ipairs(known.artists) do
				local text = artist.searchText
				if text ~= nil and text:find(needle, 1, true) then artists[#artists + 1] = artist end
			end
			for _, track in ipairs(known.tracks) do
				local text = track.searchText
				if text ~= nil and text:find(needle, 1, true) then tracks[#tracks + 1] = track end
			end
			local sweep = { needle = needle, version = self.version, albums = albums, artists = artists, tracks = tracks }
			self.sweep = sweep
			return albums, artists, tracks
		end
	end

	local sweep = sweepLibrary(self, needle)
	self.sweep = sweep
	return sweep.albums, sweep.artists, sweep.tracks
end

return Library
