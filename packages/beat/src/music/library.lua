-- The library in memory: tracks, the albums they make, and the artists those albums make.
--
-- Nothing here is persisted. A scan fills this from the filesystem, a second scan replaces it,
-- and the process ending is what forgets it. The indexes exist so a screen can ask for an album
-- by id without walking the list, not so a later launch can skip the walk.
local path = require("path")
local time = require("wonderland.time")
local names = require("beat.music.names")
local searchFold = require("beat.music.search_fold")
local searchMatch = require("beat.music.search_match")

-- Track and album records keep only the fields a page reads for every row. The rest -- the audio
-- details a scan writes and a plugin reads once, a cover path, a fingerprint -- live in columns on
-- the library, one array per field indexed by the record's id, and a shared metatable answers the
-- reads that would have found them (see `columnar`). A Lua table's hash part is sized by how many
-- fields it holds rather than by how big they are, so a track with twenty fields costs more than
-- three times the memory of one with eight, and most of those twenty are read once a launch at
-- most. Reads through the metatable are a function call, which a row that draws a title or a
-- length never pays.

---@class beat.Track
---@field id number # In the record's own table, with the fields below it
---@field path string
---@field title string
---@field artist string
---@field album string
---@field albumId number
---@field number number?
---@field duration number
---@field artistId number # In a column; still read as a field
---@field albumArtist string
---@field disc number
---@field year number?
---@field genre string?
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
---@field id number # In the album's own table, with the fields below it
---@field key string
---@field title string
---@field artist string
---@field tracks beat.Track[]
---@field artistId number # In a column; still read as a field
---@field year number?
---@field coverPath string?
---@field coverCache string?
---@field coverTrack beat.Track?
---@field modified number # The newest file in the album, in seconds
---@field single boolean? # True when the album is one file with no album tag, titled after it
---@field trackCount number # Computed from `tracks` each read
---@field duration number # Computed from the tracks' lengths each read
---@field searchText string? # Folded title and artist, made on the first search

---@class beat.Artist
---@field id number
---@field name string
---@field albums beat.Album[]
---@field tracks beat.Track[]
---@field searchText string? # The folded name, made on the first search

--- What one search answered, kept so the same query asked again -- a frame of the search page --
--- is the same lists rather than another pass over the library.
---@class beat.SearchSweep
---@field needle string # The folded query this answers
---@field version number # The library version it was computed for
---@field albums beat.Album[]
---@field artists beat.Artist[]
---@field tracks beat.Track[]

---@class beat.Library
---@field recentAdded { limit: number?, version: number, count: number, list: beat.Album[] }?
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
---@field columns table<string, table<number, any>> # A track's rarely read fields, by field then id; never replaced, only written
---@field albumColumns table<string, table<number, any>> # The same for an album
---@field trackMeta table # Serves `columns` to the tracks this library made
---@field albumMeta table # Serves `albumColumns` and the computed fields to the albums
---@field sweep beat.SearchSweep? # The last search, answered again for the same query
---@field searchWords beat.SearchWords? # The distinct words of the search text, for typos
---@field nextTrackId number # The id the next track is given; ids are never reused
---@field nextAlbumId number
---@field nextArtistId number
---@field version number
---@field ready boolean
---@field finishing beat.LibraryFinish? # What is left of a closing sort that ran out of its slice
local Library = {}
Library.__index = Library

--- The metatable a record of a library is given: a read of a field it does not hold in its own
--- table finds the column for that field, or a value computed from the record, and a write of such
--- a field goes into the column rather than into the table (where it would grow the field count
--- the table pays for). A field the record does hold -- a title, its list of tracks -- is read and
--- written as before without coming here.
---@param columns table<string, table<number, any>>
---@param computed table<string, fun(record: any): any>?
---@return table
local function columnar(columns, computed)
	local function read(record, key)
		local column = columns[key]
		if column ~= nil then return column[record.id] end
		if computed ~= nil then
			local compute = computed[key]
			if compute ~= nil then return compute(record) end
		end
		return nil
	end

	local function write(record, key, value)
		local column = columns[key]
		if column == nil then
			if value == nil then return end
			column = {}
			columns[key] = column
		end
		column[record.id] = value
	end

	return { __index = read, __newindex = write }
end

--- Forgets everything a record had in a column, so dropping it from the library also drops the
--- strings only it held.
---@param columns table<string, table<number, any>>
---@param id number
local function dropColumns(columns, id)
	for _, column in pairs(columns) do column[id] = nil end
end

---@param root string
---@return beat.Library
function Library.new(root)
	local library = setmetatable({
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
		columns = {},
		albumColumns = {},
		sweep = nil,
		version = 0,
		ready = false,
		-- Ids are handed out from counters rather than from the list length: removing the tracks of
		-- a folder leaves gaps, and a later add must not reuse an id something still refers to.
		nextTrackId = 1,
		nextAlbumId = 1,
		nextArtistId = 1
	}, Library)

	library.trackMeta = columnar(library.columns)
	library.albumMeta = columnar(library.albumColumns, {
		trackCount = function(album) return #album.tracks end,
		duration = function(album)
			local total = 0
			for _, track in ipairs(album.tracks) do total += track.duration end
			return total
		end
	})
	return library
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
		album = setmetatable({
			id = albumId,
			key = key,
			title = track.album,
			artist = track.albumArtist,
			tracks = {}
		}, self.albumMeta)
		album.year = track.year
		album.coverPath = track.coverPath
		album.coverCache = track.coverCache
		album.coverTrack = track.hasPicture and track or nil
		album.modified = track.modified
		album.single = names.isSingleKey(key) or nil

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

--- The album key a track is filed under. A scan that already decided which album a file belongs
--- to hands that key over: what a file was grouped into is not always something its own tags say
--- twice, and a cache replaying the tags alone would group it again into an album of its own.
--- Otherwise the tags and the file's path make the key, and a file with no album tag is a single.
---@param tags table<string, any>?
---@param dir string
---@param file string
---@param key string?
---@return string
local function albumKeyOf(tags, dir, file, key)
	if key ~= nil then return key end
	return names.albumKey(tags, dir, file)
end

--- Adds one inspected file. `entry` is what the scanner found; `cover` is the folder picture, if
--- one was beside the file, which a single does not use.
---@param info treble.audio.Inspect
---@param entry { path: string, dir: string, name: string, ext: string, modifyTime: number?, key: string? }
---@param cover string?
---@param coverCache string?
--- Drops a closing sort a change made stale: the album and artist orders it was building are
--- copies made before the new track arrived, and filing it under them would drop it from the order
--- altogether. The next slice starts a sort over the lists as they are now, which is cheaper than
--- sorting the whole library inside the add.
---@param self beat.Library
local function abandonSort(self)
	if self.finishing ~= nil then
		self.finishing = nil
		self.ready = false
	end
end

---@return beat.Track
---@return boolean gainedCover # Whether this was the album's first cached cover
function Library:add(info, entry, cover, coverCache)
	abandonSort(self)
	local tags = info.tags or {}
	local base = names.stripExtension(entry.name)
	local title = hasText(tags.title) and tags.title or names.stripTrackPrefix(base)
	local single = not hasText(tags.album)

	-- A file that names no artist is unknown; nothing about the folder it sits in says otherwise.
	local artist = intern(self, hasText(tags.artist) and tags.artist or "Unknown Artist") or ""
	-- A file that names no album is a single, and its own title names its album.
	local albumTitle = intern(self, hasText(tags.album) and tags.album or title) or ""
	local albumArtist = intern(self, hasText(tags.albumArtist) and tags.albumArtist or artist) or ""

	local number = tags.track
	if number == nil then
		number = tonumber(entry.name:match("^%s*(%d+)"))
	end

	local id = self.nextTrackId
	self.nextTrackId = id + 1

	-- A folder picture belongs to a folder of one album; a single is its own album and may only
	-- show a picture from its own file.
	local coverPath = nil
	if not single then coverPath = intern(self, cover) end

	---@type beat.Track
	local track = setmetatable({
		id = id,
		path = entry.path,
		title = title,
		artist = artist,
		album = albumTitle,
		albumId = 0,
		duration = info.duration or 0,
		number = number
	}, self.trackMeta)
	track.albumArtist = albumArtist
	track.disc = tags.disc or 1
	track.year = names.yearOf(tags.date)
	track.genre = intern(self, tags.genre)
	track.format = intern(self, info.format) or ""
	track.sampleRate = info.sampleRate
	track.channels = info.channels
	track.hasPicture = info.hasPicture
	track.coverPath = coverPath
	track.coverCache = intern(self, coverCache)
	track.modified = entry.modifyTime or 0
	track.fingerprint = info.fingerprint

	return place(self, track, albumKeyOf(tags, entry.dir, entry.path, entry.key))
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

--- Adds one track a cache wrote down: the values `add` derives from a scan's tags and path are
--- already there, so nothing here re-derives a title from a file name. A launch reads thousands of
--- these before it draws anything, and the tables and the folded strings a derivation would make
--- for each were most of the garbage and a third of the time.
---@param record table # One `packed` record from the cache
---@return beat.Track
---@return boolean gainedCover # Whether this was the album's first cached cover
function Library:addCached(record)
	abandonSort(self)
	local file = record.path
	assert(type(file) == "string", "a cached track needs its path")
	local title = textOf(record.title)
	local artist = intern(self, textOf(record.artist)) or ""
	local albumTitle = intern(self, textOf(record.album)) or ""
	local albumArtist = intern(self, textOf(record.albumArtist)) or ""
	local key = textOf(record.key)
	local hadAlbum = albumTitle ~= ""

	if title == nil or title == "" or artist == "" or albumTitle == "" or albumArtist == "" or key == nil then
		-- A record that does not say everything is filled in the way a scan would fill it in: a
		-- missing artist is unknown, and a missing album makes the track a single named after its
		-- own title. What the cache does say is kept; interning a value twice hands back the copy
		-- already in the library.
		local dir = path.dirname(file)
		if title == nil or title == "" then
			title = names.stripTrackPrefix(names.stripExtension(path.basename(file)))
		end
		if artist == "" then artist = intern(self, "Unknown Artist") or "" end
		if albumTitle == "" then albumTitle = intern(self, title) or "" end
		if albumArtist == "" then albumArtist = artist end
		if key == nil then
			if hadAlbum then
				key = names.albumKey({ album = albumTitle, albumArtist = albumArtist }, dir, file)
			else
				key = names.albumKey({ albumArtist = albumArtist }, dir, file)
			end
		end
	end

	local id = self.nextTrackId
	self.nextTrackId = id + 1

	---@cast key string
	-- A single's album is its file, not the folder it sits in, so a folder picture is not its cover.
	local coverPath = intern(self, textOf(record.coverPath))
	if names.isSingleKey(key) then coverPath = nil end

	---@type beat.Track
	local track = setmetatable({
		id = id,
		path = file,
		title = title,
		artist = artist,
		album = albumTitle,
		albumId = 0,
		duration = numberOr(record.duration, 0),
		number = numberOf(record.number)
	}, self.trackMeta)
	track.albumArtist = albumArtist
	track.disc = numberOr(record.disc, 1)
	track.year = numberOf(record.year)
	track.genre = intern(self, textOf(record.genre))
	track.format = intern(self, textOf(record.format)) or ""
	track.sampleRate = numberOr(record.sampleRate, 0)
	track.channels = numberOr(record.channels, 0)
	track.hasPicture = record.hasPicture == true
	track.coverPath = coverPath
	track.coverCache = intern(self, textOf(record.coverCache))
	track.modified = numberOr(record.modified, 0)
	track.fingerprint = textOf(record.fingerprint)

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
	abandonSort(self)
	local fold = path.separator == "\\"
	local base = path.normalize(folder)
	if fold then base = base:lower() end
	local prefix = base:sub(-1) == path.separator and base or base .. path.separator

	local tracks = {}
	local removed = false
	local columns = self.columns
	for _, track in ipairs(self.tracks) do
		if under(base, prefix, fold, track.path) then
			self.trackById[track.id] = nil
			dropColumns(columns, track.id)
			removed = true
		else
			tracks[#tracks + 1] = track
		end
	end
	if not removed then return false end
	self.tracks = tracks

	local albums = {}
	local albumColumns = self.albumColumns
	for _, album in ipairs(self.albums) do
		local kept = {}
		for _, track in ipairs(album.tracks) do
			if not under(base, prefix, fold, track.path) then kept[#kept + 1] = track end
		end

		if #kept > 0 then
			album.tracks = kept
			-- Rebuilt by `finish` from what is left, rather than left pointing into the folder
			-- that is gone.
			album.coverTrack = nil
			album.coverPath = nil
			albums[#albums + 1] = album
		else
			self.albumById[album.id] = nil
			self.albumByKey[album.key] = nil
			dropColumns(albumColumns, album.id)
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

-- The names the closing sort is reading, folded once instead of inside every comparison. They are
-- module state rather than upvalues of a comparator made per sort: a `finishStep` resumes on a
-- later tick, and the comparator it left mid-sort has to find the same maps.
local finishTitles, finishArtists, finishArtistNames = {}, {}, {}

local function byFinishName(a, b)
	local at, bt = finishTitles[a], finishTitles[b]
	if at ~= bt then return at < bt end
	return finishArtists[a] < finishArtists[b]
end

local function byFinishArtist(a, b)
	return finishArtistNames[a] < finishArtistNames[b]
end

--- What a `finishStep` has left to do: the phase it stopped in, the index it stopped at, and what
--- the phases after it read.
---@class beat.LibraryFinish
---@field phase string
---@field at number
---@field titles table<beat.Album, string>
---@field artists table<beat.Album, string>
---@field orderedAlbums beat.Album[]
---@field orderedArtists beat.Artist[]
---@field artistNames table<beat.Artist, string>

--- Closes the scan a share of a frame at a time: sorts what was found and fills in the values a
--- screen reads for an album -- the first track that carries a picture, the first that names a
--- folder picture. The album's length and track count are summed where they are read instead of
--- being kept up to date here. The budget is an absolute time (as `wonderland.time.now` reads);
--- `math.huge` finishes the whole thing, which is what `finish` does for a caller that needs the
--- library sorted now.
---
--- The per-album pass is the expensive one -- a library of a few thousand tracks is a few hundred
--- small sorts, each folding two titles per comparison -- so every album is its own step. The
--- folded names and per-artist lists are built the same way, and the two `table.sort` calls that
--- order albums and artists are a few hundred entries each: they run in the slice that reaches them.
---@param deadline number
---@return boolean done # False when the budget ran out and another call should continue
function Library:finishStep(deadline)
	local state = self.finishing
	if state == nil then
		state = {
			phase = "tracks",
			at = 1,
			titles = {},
			artists = {},
			orderedAlbums = {},
			orderedArtists = {},
			artistNames = {}
		}
		self.finishing = state --[[@as beat.LibraryFinish]]
	end
	---@cast state beat.LibraryFinish

	if state.phase == "tracks" then
		local albums = self.albums
		for at = state.at, #albums do
			local album = albums[at]
			table.sort(album.tracks, trackOrder)
			local coverTrack, coverPath = album.coverTrack, album.coverPath
			for _, track in ipairs(album.tracks) do
				if coverTrack == nil and track.hasPicture then coverTrack = track end
				if coverPath == nil then coverPath = track.coverPath end
			end
			album.coverTrack = coverTrack
			album.coverPath = coverPath
			if time.now() >= deadline then
				state.at = at + 1
				return false
			end
		end
		state.phase = "albumNames"
		state.at = 1
	end

	if state.phase == "albumNames" then
		local albums, titles, artists = self.albums, state.titles, state.artists
		for at = state.at, #albums do
			local album = albums[at]
			titles[album] = names.fold(album.title)
			artists[album] = names.fold(album.artist)
			if time.now() >= deadline then
				state.at = at + 1
				return false
			end
		end
		finishTitles, finishArtists = titles, artists
		local ordered = state.orderedAlbums
		for _, album in ipairs(albums) do ordered[#ordered + 1] = album end
		table.sort(ordered, byFinishName)
		self.albums = ordered
		state.phase = "artists"
		state.at = 1
	end

	if state.phase == "artists" then
		finishTitles, finishArtists = state.titles, state.artists
		local artists = self.artists
		local orderedArtists, artistNames = state.orderedArtists, state.artistNames
		for at = state.at, #artists do
			local artist = artists[at]
			local albums = {}
			for _, album in pairs(artist.albums) do albums[#albums + 1] = album end
			table.sort(albums, byFinishName)
			artist.albums = albums
			table.sort(artist.tracks, trackOrder)
			orderedArtists[#orderedArtists + 1] = artist
			artistNames[artist] = names.fold(artist.name)
			if time.now() >= deadline then
				state.at = at + 1
				return false
			end
		end
		state.phase = "artistOrder"
	end

	finishArtistNames = state.artistNames
	table.sort(state.orderedArtists, byFinishArtist)
	self.artists = state.orderedArtists

	self.ready = true
	self.sweep = nil
	self.version += 1
	-- The interning table is what makes a tag value that repeats by the thousand one string while
	-- the scan reads it; once the scan is over, every value it holds is already on the track or
	-- album that showed it, and the table itself is tens of kilobytes of hash. A later folder add
	-- fills it again, from the folder it adds, which is the only strings it has to dedupe.
	self.strings = {}
	self.finishing = nil
	return true
end

--- Closes the scan now, for a caller that needs the sorted library before it continues: a test, a
--- cache read on this thread, a service being closed.
function Library:finish()
	self:finishStep(math.huge)
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
	local kept = self.recentAdded
	if kept ~= nil and kept.limit == limit and kept.version == self.version and kept.count == #self.recent then
		return kept.list
	end
	local list = {}
	for index = #self.recent, 1, -1 do
		list[#list + 1] = self.recent[index]
		if limit ~= nil and #list >= limit then break end
	end
	self.recentAdded = { limit = limit, version = self.version, count = #self.recent, list = list }
	return list
end

---@class beat.SearchWords
---@field words string[] # Every distinct folded word the library's text holds
---@field letters number[] # Each word's letters a-z, as bits
---@field known table<string, boolean>

--- Adds the words of one folded text the list has not seen yet. A typo is looked for among
--- these rather than in every title, so each distinct word is compared once per query.
---@param vocabulary beat.SearchWords
---@param text string
local function learn(vocabulary, text)
	local known, words, letters = vocabulary.known, vocabulary.words, vocabulary.letters
	local start, length = 1, #text
	while start <= length do
		local stop = text:find(" ", start, true) or (length + 1)
		local word = text:sub(start, stop - 1)
		if not known[word] then
			known[word] = true
			local at = #words + 1
			words[at] = word
			letters[at] = searchMatch.lettersOf(word)
		end
		start = stop + 1
	end
end

--- The folded text of everything a search looks in, made where it is missing. Only the first
--- search of a library writes them; every later one finds the fields already there. They are kept
--- on the album, artist and track because a title, an artist and an album do not change once the
--- item is in the library, so the text cannot go stale. `forgetSearch` drops them again when the
--- field empties.
---@param self beat.Library
local function prepareSearch(self)
	local vocabulary = self.searchWords
	if vocabulary == nil then
		vocabulary = { words = {}, letters = {}, known = {} } --[[@as beat.SearchWords]]
		self.searchWords = vocabulary
	end
	---@cast vocabulary beat.SearchWords

	for _, album in ipairs(self.albums) do
		if album.searchText == nil then
			album.searchText = searchFold.text(album.title .. " " .. album.artist)
			learn(vocabulary, album.searchText)
		end
	end
	for _, artist in ipairs(self.artists) do
		if artist.searchText == nil then
			artist.searchText = searchFold.text(artist.name)
			learn(vocabulary, artist.searchText)
		end
	end
	-- A track's folded text is a string of a hundred bytes and more, which is too much to keep on
	-- thousands of track tables for a search nobody may type again: it lives in a column, so
	-- dropping it is giving the column back.
	local texts = self.columns.searchText
	if texts == nil then
		texts = {}
		self.columns.searchText = texts
	end
	for _, track in ipairs(self.tracks) do
		if texts[track.id] == nil then
			local text = searchFold.text(track.title .. " " .. track.artist .. " " .. track.album)
			texts[track.id] = text
			learn(vocabulary, text)
		end
	end
end

--- Drops the folded text and the word list the last search made. The search screen calls this
--- when its query empties: it is a few hundred kilobytes of strings kept for a search nobody is
--- looking at, and the next search folds the library again in one pass.
function Library:forgetSearch()
	for _, album in ipairs(self.albums) do album.searchText = nil end
	for _, artist in ipairs(self.artists) do artist.searchText = nil end
	self.columns.searchText = nil
	self.searchWords = nil
	self.sweep = nil
end

--- The items of `list` the prepared query finds: those that hold every word as written first,
--- then those that hold them with typos, each in the list's own order.
---@param list table[] # Albums, artists or tracks, each with its folded `searchText`
---@return table[]
local function found(list)
	---@type table[], table[]?
	local exact, near = {}, nil
	for at = 1, #list do
		local item = list[at]
		local score = searchMatch.score(item.searchText)
		if score == 2 then
			exact[#exact + 1] = item
		elseif score == 1 then
			near = near or {}
			near[#near + 1] = item
		end
	end
	if near ~= nil then
		for at = 1, #near do exact[#exact + 1] = near[at] end
	end
	return exact
end

--- Albums, artists and tracks whose text holds every word of the query, with or without accents,
--- in any case and in any order; a word of four letters or more may also be off by a typo. What
--- holds the words as typed comes before what holds them with a typo.
---@param query string
---@return beat.Album[] albums, beat.Artist[] artists, beat.Track[] tracks
function Library:search(query)
	local needle = searchFold.text(query)
	if needle == "" then return {}, {}, {} end

	local known = self.sweep
	if known ~= nil and known.version == self.version and known.needle == needle then
		return known.albums, known.artists, known.tracks
	end

	prepareSearch(self)
	local vocabulary = assert(self.searchWords)
	searchMatch.prepare(needle, vocabulary.words, vocabulary.letters)
	local sweep = {
		needle = needle,
		version = self.version,
		albums = found(self.albums),
		artists = found(self.artists),
		tracks = found(self.tracks)
	}
	self.sweep = sweep
	return sweep.albums, sweep.artists, sweep.tracks
end

return Library
