-- Tags and playlists. Tags belong to tracks and are what both smart playlists and the search
-- filters are built from; a manual playlist is a hidden tag of its own, so membership has one
-- representation whether the person tagged a song or dragged it into a playlist.
--
-- A track is filed under `names.trackKey`: the fingerprint of its audio where the scan has one,
-- so a file that was moved or renamed keeps the listener's tags, rating and plays, and its path
-- where it has none. A version-1 file keyed everything by path and is read into `legacy`, which
-- `adopt` empties onto keys as soon as a library holds those paths.
local names = require("beat.music.names")

---@class beat.Tag
---@field id number
---@field name string
---@field hidden boolean
---@field playlistId number? # Set on the hidden tag that holds a manual playlist's tracks
---@field count number

---@class beat.Playlist
---@field id number
---@field name string
---@field smart boolean # Whether tag criteria contribute tracks
---@field tagIds number[]
---@field match "all"|"any"
---@field manual boolean # Whether hand-added tracks contribute
---@field hiddenTagId number? # The hidden tag that holds hand-added tracks
---@field autoTagId number? # The tag whose automatic playlist this is, where one made it
---@field updatedAt number # Last change to the playlist or its membership

---@class beat.Metric
---@field count number
---@field last number

--- What a version-1 file kept by path, waiting for a library to say which track path is.
---@class beat.LegacyTaxonomy
---@field byPath table<string, table<number, boolean>>
---@field ratings table<string, number>
---@field metrics table<string, beat.Metric>

---@class beat.Taxonomy
---@field tags beat.Tag[]
---@field tagById table<number, beat.Tag>
---@field tagByName table<string, beat.Tag>
---@field byKey table<string, table<number, boolean>> # Tag ids per `names.trackKey`
---@field playlists beat.Playlist[]
---@field playlistById table<number, beat.Playlist>
---@field nextTagId number
---@field nextPlaylistId number
---@field albumRatings table<string, number> # By album key
---@field ratings table<string, number> # By track key
---@field metrics { tracks: table<string, beat.Metric>, albums: table<string, beat.Metric>, tags: table<number, beat.Metric>, playlists: table<number, beat.Metric> }
---@field legacy beat.LegacyTaxonomy # Path-keyed entries no library has claimed yet
local Taxonomy = {}
Taxonomy.__index = Taxonomy

---@return beat.Taxonomy
function Taxonomy.new()
	return setmetatable(
		{
			tags = {},
			tagById = {},
			tagByName = {},
			byKey = {},
			playlists = {},
			playlistById = {},
			nextTagId = 1,
			nextPlaylistId = 1,
			albumRatings = {},
			ratings = {},
			metrics = { tracks = {}, albums = {}, tags = {}, playlists = {} },
			legacy = { byPath = {}, ratings = {}, metrics = {} }
		},
		Taxonomy
	)
end

---@param value string?
local function cleanName(value)
	return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

---@param value string
---@return string
local function nameKey(value)
	return names.fold(cleanName(value))
end

---@param tag beat.Tag
local function recount(tag)
	tag.count = 0
end

---@param self beat.Taxonomy
local function useTags(self)
	for _, tag in ipairs(self.tags) do recount(tag) end
	-- A legacy set still belongs on a tag: the tag is real, only the track it names has not been
	-- matched to its key yet.
	for _, map in ipairs({ self.byKey, self.legacy.byPath }) do
		for _, set in pairs(map) do
			for id in pairs(set) do
				local tag = self.tagById[id]
				if tag ~= nil then tag.count += 1 end
			end
		end
	end
end

--- A visible tag. Names are unique without regard to case; the first spelling wins.
---@param name string
---@return beat.Tag?
function Taxonomy:addTag(name)
	local display = cleanName(name)
	local key = nameKey(display)
	if display == "" or self.tagByName[key] ~= nil then return nil end

	local tag = { id = self.nextTagId, name = display, hidden = false, count = 0 }
	self.nextTagId += 1
	self.tags[#self.tags + 1] = tag
	self.tagById[tag.id] = tag
	self.tagByName[key] = tag

	-- A tag is also a smart playlist: same name, one tag, and maintained by tag assignments.
	local playlist = self:addPlaylist(tag.name, true, { tag.id }, "all", { manual = false, autoTagId = tag.id })
	if playlist ~= nil then tag.playlistId = playlist.id end
	return tag
end

---@param playlistId number
---@return beat.Tag
function Taxonomy:addHiddenPlaylistTag(playlistId)
	local tag = {
		id = self.nextTagId,
		name = "__playlist_" .. tostring(playlistId),
		hidden = true,
		playlistId = playlistId,
		count = 0
	}
	self.nextTagId += 1
	self.tags[#self.tags + 1] = tag
	self.tagById[tag.id] = tag
	return tag
end

---@return beat.Tag[]
function Taxonomy:visibleTags()
	local tags = {}
	for _, tag in ipairs(self.tags) do
		if not tag.hidden then tags[#tags + 1] = tag end
	end
	return tags
end

---@param key string # `names.trackKey(track)`
---@param tagId number
---@return boolean
function Taxonomy:isTagged(key, tagId)
	local set = self.byKey[key]
	return set ~= nil and set[tagId] == true
end

---@param key string # `names.trackKey(track)`
---@param tagId number
---@param on boolean
function Taxonomy:setTag(key, tagId, on)
	if self.tagById[tagId] == nil then return end
	local set = self.byKey[key]
	if on then
		if set == nil then
			set = {}
			self.byKey[key] = set
		end
		if not set[tagId] then
			set[tagId] = true
			local tag = self.tagById[tagId]
			if tag ~= nil then tag.count += 1 end
			for _, playlist in ipairs(self.playlists) do
				if playlist.smart then
					for _, id in ipairs(playlist.tagIds) do
						if id == tagId then
							playlist.updatedAt = os.time()
							break
						end
					end
				end
			end
		end
	elseif set ~= nil and set[tagId] then
		set[tagId] = nil
		local tag = self.tagById[tagId]
		if tag ~= nil then tag.count = math.max(0, tag.count - 1) end
		local empty = true
		for _ in pairs(set) do
			empty = false
			break
		end
		if empty then self.byKey[key] = nil end
	end
end

---@param s number?
local clampRating = |s| -> math.max(0, math.min(5, math.floor(s or 0)))

---@param key string # `names.trackKey(track)`
---@return number # 0 when unrated
function Taxonomy:rating(key)
	return self.ratings[key] or 0
end

--- 1-5 stars, 0 for unrated.
---@param key string # `names.trackKey(track)`
---@param value number
function Taxonomy:setRating(key, value)
	value = clampRating(value)
	self.ratings[key] = value > 0 ? value : nil
end

---@param key string
---@return number # 0 when unrated
function Taxonomy:albumRating(key)
	return self.albumRatings[key] or 0
end

--- 1-5 stars, 0 for unrated.
---@param key string
---@param value number
function Taxonomy:setAlbumRating(key, value)
	value = clampRating(value)
	self.albumRatings[key] = value > 0 ? value : nil
end

---@param key string # `names.trackKey(track)`
---@param tagId number
---@return boolean state
function Taxonomy:toggleTag(key, tagId)
	local on = not self:isTagged(key, tagId)
	self:setTag(key, tagId, on)
	return on
end

---@param key string # `names.trackKey(track)`
---@param tagIds number[]
---@param match "all"|"any"
---@return boolean
function Taxonomy:matches(key, tagIds, match)
	if #tagIds == 0 then return false end
	local set = self.byKey[key]
	if set == nil then return false end
	if match == "any" then
		for _, id in ipairs(tagIds) do
			if set[id] then return true end
		end
		return false
	end
	for _, id in ipairs(tagIds) do
		if not set[id] then return false end
	end
	return true
end

---@param name string
---@param smart boolean? # Kept for callers that only think in the old two kinds
---@param tagIds number[]?
---@param match "all"|"any"?
---@param opts { manual: boolean?, autoTagId: number?, now: number? }?
---@return beat.Playlist?
function Taxonomy:addPlaylist(name, smart, tagIds, match, opts)
	local display = cleanName(name)
	if display == "" then return nil end
	opts = opts or {}

	local playlist = {
		id = self.nextPlaylistId,
		name = display,
		smart = smart == true,
		tagIds = {},
		match = match == "any" ? "any" : "all",
		manual = opts.manual ~= false,
		autoTagId = opts.autoTagId,
		updatedAt = opts.now or os.time()
	}
	self.nextPlaylistId += 1

	local seen = {}
	for _, id in ipairs(tagIds or {}) do
		local tag = self.tagById[id]
		if tag ~= nil and not tag.hidden and not seen[id] then
			seen[id] = true
			playlist.tagIds[#playlist.tagIds + 1] = id
		end
	end
	playlist.smart = smart == true or #playlist.tagIds > 0

	-- Every playlist can be edited by hand; the hidden tag holds those additions even where no
	-- tag criteria exist.
	playlist.hiddenTagId = self:addHiddenPlaylistTag(playlist.id).id

	self.playlists[#self.playlists + 1] = playlist
	self.playlistById[playlist.id] = playlist
	return playlist
end

---@param playlistId number
---@return beat.Playlist?
function Taxonomy:playlist(playlistId)
	return self.playlistById[playlistId]
end

---@param playlist beat.Playlist
---@param library beat.Library
---@return beat.Track[]
function Taxonomy:playlistTracks(playlist, library)
	local tracks = {}
	for _, track in ipairs(library.tracks) do
		local key = names.trackKey(track)
		local smartMatch = playlist.smart and self:matches(key, playlist.tagIds, playlist.match)
		local manualMatch = playlist.manual and playlist.hiddenTagId ~= nil and self:isTagged(
			key,
			playlist.hiddenTagId
		)
		if smartMatch or manualMatch then tracks[#tracks + 1] = track end
	end
	return tracks
end

---@param playlist beat.Playlist
---@param key string # `names.trackKey(track)`
---@param on boolean
function Taxonomy:setPlaylistTrack(playlist, key, on)
	local hidden = playlist.hiddenTagId
	if hidden == nil then return end
	local was = self:isTagged(key, hidden)
	if was ~= on then
		playlist.updatedAt = os.time()
		if on then playlist.manual = true end
		self:setTag(key, hidden, on)
	end
end

---@param playlist beat.Playlist
---@param album beat.Album
---@param on boolean?
function Taxonomy:setPlaylistAlbum(playlist, album, on)
	if on == false then
		for _, track in ipairs(album.tracks) do self:setPlaylistTrack(playlist, names.trackKey(track), false) end
	else
		for _, track in ipairs(album.tracks) do self:setPlaylistTrack(playlist, names.trackKey(track), true) end
	end
end

---@param tagId number
function Taxonomy:removeTag(tagId)
	local tag = self.tagById[tagId]
	if tag == nil then return end
	self.tagById[tagId] = nil
	if not tag.hidden then self.tagByName[nameKey(tag.name)] = nil end
	for at = #self.tags, 1, -1 do
		if self.tags[at].id == tagId then table.remove(self.tags, at) end
	end
	-- The legacy entries too: a tag removed before its path was adopted must not come back with it.
	for _, map in ipairs({ self.byKey, self.legacy.byPath }) do
		for key, set in pairs(map) do
			if set[tagId] then
				set[tagId] = nil
				local empty = true
				for _ in pairs(set) do
					empty = false
					break
				end
				if empty then map[key] = nil end
			end
		end
	end
	local removing = {}
	for _, playlist in ipairs(self.playlists) do
		if playlist.autoTagId == tagId then
			removing[#removing + 1] = playlist.id
		elseif playlist.smart then
			for at = #playlist.tagIds, 1, -1 do
				if playlist.tagIds[at] == tagId then table.remove(playlist.tagIds, at) end
			end
			playlist.smart = #playlist.tagIds > 0
			playlist.updatedAt = os.time()
		end
	end
	for _, id in ipairs(removing) do self:removePlaylist(id) end
	self.metrics.tags[tagId] = nil
end

--- A visible tag renamed in place keeps its id and every reference to it; only what is shown
--- changes. The automatic playlist that carries its name changes with it.
---@param tagId number
---@param name string
---@return beat.Tag?
function Taxonomy:renameTag(tagId, name)
	local tag = self.tagById[tagId]
	local display = cleanName(name)
	local key = nameKey(display)
	if tag == nil or tag.hidden or display == "" then return nil end
	local other = self.tagByName[key]
	if other ~= nil and other.id ~= tag.id then return nil end

	self.tagByName[nameKey(tag.name)] = nil
	tag.name = display
	self.tagByName[key] = tag
	for _, playlist in ipairs(self.playlists) do
		if playlist.autoTagId == tag.id then
			playlist.name = display
			playlist.updatedAt = os.time()
		end
	end
	return tag
end

--- Playlists for tags that were loaded without their automatic playlist.
function Taxonomy:ensureTagPlaylists()
	for _, tag in ipairs(self.tags) do
		if not tag.hidden then
			local found = false
			for _, playlist in ipairs(self.playlists) do
				if playlist.autoTagId == tag.id then
					found = true
					break
				end
			end
			if not found then
				local playlist = self:addPlaylist(tag.name, true, { tag.id }, "all", { manual = false, autoTagId = tag.id })
				if playlist ~= nil then tag.playlistId = playlist.id end
			end
		end
	end
end

---@param playlistId number
function Taxonomy:removePlaylist(playlistId)
	local playlist = self.playlistById[playlistId]
	if playlist == nil then return end
	self.playlistById[playlistId] = nil
	for at = #self.playlists, 1, -1 do
		if self.playlists[at].id == playlistId then table.remove(self.playlists, at) end
	end
	if playlist.hiddenTagId ~= nil then self:removeTag(playlist.hiddenTagId) end
	self.metrics.playlists[playlistId] = nil
end

---@param map table<any, beat.Metric>
---@param key any
---@param now number
local function bump(map, key, now)
	local metric = map[key]
	if metric == nil then
		metric = { count = 0, last = 0 }
		map[key] = metric
	end
	metric.count += 1
	metric.last = now
end

--- One track started being heard: it counts for the track, its album, every visible tag on it and
--- the playlist that started it, where one did.
---@param track beat.Track
---@param library beat.Library
---@param playlistId number?
---@param now number?
function Taxonomy:recordListen(track, library, playlistId, now)
	now = now or os.time()
	local key = names.trackKey(track)
	bump(self.metrics.tracks, key, now)
	local album = library:album(track.albumId)
	if album ~= nil then bump(self.metrics.albums, album.key, now) end
	local set = self.byKey[key]
	if set ~= nil then
		for id in pairs(set) do
			local tag = self.tagById[id]
			if tag ~= nil and not tag.hidden then bump(self.metrics.tags, id, now) end
		end
	end
	if playlistId ~= nil then bump(self.metrics.playlists, playlistId, now) end
end

---@param track beat.Track
---@return beat.Metric?
function Taxonomy:trackMetric(track)
	return self.metrics.tracks[names.trackKey(track)]
end

---@param album beat.Album
---@return beat.Metric?
function Taxonomy:albumMetric(album)
	return self.metrics.albums[album.key]
end

--- Albums heard, newest last-heard first.
---@param library beat.Library
---@param limit number?
---@return beat.Album[]
function Taxonomy:recentAlbums(library, limit)
	local entries = {}
	for _, album in ipairs(library.albums) do
		local metric = self.metrics.albums[album.key]
		if metric ~= nil then entries[#entries + 1] = { album = album, last = metric.last } end
	end
	table.sort(entries, function(a, b)
		if a.last ~= b.last then return a.last > b.last end
		return a.album.key < b.album.key
	end)
	local albums = {}
	for at = 1, #entries do
		albums[#albums + 1] = entries[at].album
		if limit ~= nil and #albums >= limit then break end
	end
	return albums
end

---@param map table<string, any>
---@return string[]
local function sortedKeys(map)
	local keys = {}
	for key in pairs(map) do keys[#keys + 1] = key end
	table.sort(keys)
	return keys
end

--- One track's data filed under `key`, merged with what is already there: tags are a union, a
--- rating is taken only when the key has none, and play counts add while the last play is the
--- later one. Both kinds of adoption below merge this way.
---@param self beat.Taxonomy
---@param key string
---@param tags table<number, boolean>?
---@param rating number?
---@param metric beat.Metric?
local function claim(self, key, tags, rating, metric)
	if tags ~= nil then
		local set = self.byKey[key] or {}
		for id in pairs(tags) do
			if self.tagById[id] ~= nil then set[id] = true end
		end
		self.byKey[key] = next(set) ~= nil and set or nil
	end
	if rating ~= nil and self.ratings[key] == nil then self.ratings[key] = rating end
	if metric ~= nil then
		local current = self.metrics.tracks[key]
		if current == nil then
			self.metrics.tracks[key] = { count = metric.count, last = metric.last }
		else
			current.count += metric.count
			current.last = math.max(current.last, metric.last)
		end
	end
end

--- Claims what this library's tracks are owed. A version-1 entry is claimed by the track now at
--- its path. An entry filed under a track's path because it had no fingerprint then -- a scan
--- that could not read one, or a version of the app that did not compute them -- is claimed by
--- the track at that path once it has one; left alone, it would never be found again. Version-1
--- entries whose path is in no library stay in `legacy`: a folder that is not scanned yet may
--- come back, and a file dragged out of it has not said where it went.
---@param library beat.Library
---@return boolean moved # Whether anything was claimed, so the caller knows to save
function Taxonomy:adopt(library)
	local legacy = self.legacy
	local moved = false

	---@type table<string, beat.Track>
	local byPath = {}
	for _, track in ipairs(library.tracks) do byPath[track.path] = track end

	-- Every version-1 path, sorted, so that two found to be the same track resolve the same way
	-- every launch: the first path's rating wins where two disagree.
	local paths = {}
	for _, map in ipairs({ legacy.byPath, legacy.ratings, legacy.metrics }) do
		for path in pairs(map) do paths[path] = true end
	end
	for _, path in ipairs(sortedKeys(paths)) do
		local track = byPath[path]
		if track ~= nil then
			claim(self, names.trackKey(track), legacy.byPath[path], legacy.ratings[path], legacy.metrics[path])
			legacy.byPath[path], legacy.ratings[path], legacy.metrics[path] = nil, nil, nil
			moved = true
		end
	end

	for _, track in ipairs(library.tracks) do
		local key = names.trackKey(track)
		local old = names.pathKey(track.path)
		if key ~= old and (self.byKey[old] ~= nil or self.ratings[old] ~= nil or self.metrics.tracks[old] ~= nil) then
			claim(self, key, self.byKey[old], self.ratings[old], self.metrics.tracks[old])
			self.byKey[old], self.ratings[old], self.metrics.tracks[old] = nil, nil, nil
			moved = true
		end
	end

	if moved then useTags(self) end
	return moved
end

--- The tag ids a set holds, sorted, with ids whose tag is gone left out: a hand-edited file can
--- name one, and it would be written back on every save only to be dropped on every load.
---@param set table<number, boolean>
---@param self beat.Taxonomy
---@return number[]
local function setIds(self, set)
	local ids = {}
	for id in pairs(set) do
		if self.tagById[id] ~= nil then ids[#ids + 1] = id end
	end
	table.sort(ids)
	return ids
end

--- What is written to disk. A track is identified by its key -- the audio's fingerprint where the
--- scan has one -- so a file that moved keeps what the listener put on it; numeric tag ids keep
--- the definitions stable even if a file is renamed later. `legacy` holds what a version-1 file
--- kept by path and no library has claimed yet.
---@return table
function Taxonomy:pack()
	local tags = {}
	for _, tag in ipairs(self.tags) do
		tags[#tags + 1] = { id = tag.id, name = tag.name, hidden = tag.hidden == true, playlistId = tag.playlistId }
	end

	local assignments = {}
	for key, set in pairs(self.byKey) do
		local ids = setIds(self, set)
		if #ids > 0 then assignments[#assignments + 1] = { key = key, tags = ids } end
	end

	local playlists = {}
	for _, playlist in ipairs(self.playlists) do
		playlists[#playlists + 1] = {
			id = playlist.id,
			name = playlist.name,
			smart = playlist.smart == true,
			tagIds = playlist.tagIds,
			match = playlist.match,
			manual = playlist.manual ~= false,
			hiddenTagId = playlist.hiddenTagId,
			autoTagId = playlist.autoTagId,
			updatedAt = playlist.updatedAt or 0
		}
	end

	local albumRatings = {}
	for key, value in pairs(self.albumRatings) do
		albumRatings[#albumRatings + 1] = { key = key, value = value }
	end

	local ratings = {}
	for key, value in pairs(self.ratings) do
		ratings[#ratings + 1] = { key = key, value = value }
	end

	local metrics = { tracks = {}, albums = {}, tags = {}, playlists = {} }
	for key, metric in pairs(self.metrics.tracks) do
		metrics.tracks[#metrics.tracks + 1] = { key = key, count = metric.count, last = metric.last }
	end
	for key, metric in pairs(self.metrics.albums) do
		metrics.albums[#metrics.albums + 1] = { key = key, count = metric.count, last = metric.last }
	end
	for id, metric in pairs(self.metrics.tags) do
		metrics.tags[#metrics.tags + 1] = { id = id, count = metric.count, last = metric.last }
	end
	for id, metric in pairs(self.metrics.playlists) do
		metrics.playlists[#metrics.playlists + 1] = { id = id, count = metric.count, last = metric.last }
	end

	local legacy = { assignments = {}, ratings = {}, tracks = {} }
	for path, set in pairs(self.legacy.byPath) do
		local ids = setIds(self, set)
		if #ids > 0 then legacy.assignments[#legacy.assignments + 1] = { path = path, tags = ids } end
	end
	for path, value in pairs(self.legacy.ratings) do
		legacy.ratings[#legacy.ratings + 1] = { path = path, value = value }
	end
	for path, metric in pairs(self.legacy.metrics) do
		legacy.tracks[#legacy.tracks + 1] = { path = path, count = metric.count, last = metric.last }
	end

	return {
		version = 2,
		tags = tags,
		assignments = assignments,
		playlists = playlists,
		metrics = metrics,
		ratings = ratings,
		albumRatings = albumRatings,
		legacy = legacy
	}
end

---@param data table
---@return beat.Taxonomy
function Taxonomy.unpack(data)
	local self = Taxonomy.new()
	for _, raw in ipairs(data.tags or {}) do
		if type(raw) == "table" and type(raw.name) == "string" and type(raw.id) == "number" then
			local tag = {
				id = raw.id,
				name = raw.name,
				hidden = raw.hidden == true,
				playlistId = type(raw.playlistId) == "number" and raw.playlistId or nil,
				count = 0
			}
			self.tags[#self.tags + 1] = tag
			self.tagById[tag.id] = tag
			if not tag.hidden then self.tagByName[nameKey(tag.name)] = tag end
			if tag.id >= self.nextTagId then self.nextTagId = tag.id + 1 end
		end
	end
	for _, raw in ipairs(data.playlists or {}) do
		if type(raw) == "table" and type(raw.name) == "string" and type(raw.id) == "number" then
			local tagIds = {}
			for _, id in ipairs(raw.tagIds or {}) do
				if self.tagById[id] ~= nil then tagIds[#tagIds + 1] = id end
			end
			local playlist = {
				id = raw.id,
				name = raw.name,
				smart = raw.smart == true or #tagIds > 0,
				tagIds = tagIds,
				match = raw.match == "any" ? "any" : "all",
				manual = raw.manual ~= nil and raw.manual == true or (raw.smart ~= true),
				hiddenTagId = type(raw.hiddenTagId) == "number" and raw.hiddenTagId or nil,
				autoTagId = type(raw.autoTagId) == "number" and raw.autoTagId or nil,
				updatedAt = type(raw.updatedAt) == "number" and raw.updatedAt or 0
			}
			if playlist.hiddenTagId == nil or self.tagById[playlist.hiddenTagId] == nil then
				playlist.hiddenTagId = self:addHiddenPlaylistTag(playlist.id).id
			end
			self.playlists[#self.playlists + 1] = playlist
			self.playlistById[playlist.id] = playlist
			if playlist.id >= self.nextPlaylistId then self.nextPlaylistId = playlist.id + 1 end
		end
	end
	local version = data.version == 1 and 1 or 2

	if version == 1 then
		-- A version-1 file names tracks by path. Those entries wait in `legacy` until a library
		-- holds the path and `adopt` can file them under the track's key.
		for _, raw in ipairs(data.assignments or {}) do
			if type(raw) == "table" and type(raw.path) == "string" then
				local set = {}
				for _, id in ipairs(raw.tags or {}) do
					if self.tagById[id] ~= nil then set[id] = true end
				end
				if next(set) ~= nil then self.legacy.byPath[raw.path] = set end
			end
		end
		for _, raw in ipairs(data.ratings or {}) do
			if type(raw) == "table" and type(raw.path) == "string" and type(raw.value) == "number" then
				local value = clampRating(raw.value)
				if value > 0 then self.legacy.ratings[raw.path] = value end
			end
		end
	else
		for _, raw in ipairs(data.assignments or {}) do
			if type(raw) == "table" and type(raw.key) == "string" then
				local set = {}
				for _, id in ipairs(raw.tags or {}) do
					if self.tagById[id] ~= nil then set[id] = true end
				end
				if next(set) ~= nil then self.byKey[raw.key] = set end
			end
		end
		for _, raw in ipairs(data.ratings or {}) do
			if type(raw) == "table" and type(raw.key) == "string" and type(raw.value) == "number" then
				local value = clampRating(raw.value)
				if value > 0 then self.ratings[raw.key] = value end
			end
		end
	end

	for _, raw in ipairs(data.albumRatings or {}) do
		if type(raw) == "table" then
			local key = version == 1 and raw.path or raw.key
			if type(key) == "string" and type(raw.value) == "number" then
				self.albumRatings[key] = clampRating(raw.value)
			end
		end
	end

	---@type { tracks: any[], albums: any[], tags: any[], playlists: any[] }
	local metrics = data.metrics or {}
	for _, raw in ipairs(metrics.tracks or {}) do
		---@cast raw { key: string?, id: number?, count: number?, last: number? }
		if type(raw.key) == "string" then
			if version == 1 then
				self.legacy.metrics[raw.key] = { count = raw.count or 0, last = raw.last or 0 }
			else
				self.metrics.tracks[raw.key] = { count = raw.count or 0, last = raw.last or 0 }
			end
		end
	end
	for _, raw in ipairs(metrics.albums or {}) do
		---@cast raw { key: string?, id: number?, count: number?, last: number? }
		if type(raw.key) == "string" then
			self.metrics.albums[raw.key] = { count = raw.count or 0, last = raw.last or 0 }
		end
	end
	for _, raw in ipairs(metrics.tags or {}) do
		---@cast raw { key: string?, id: number?, count: number?, last: number? }
		if type(raw.id) == "number" then
			self.metrics.tags[raw.id] = { count = raw.count or 0, last = raw.last or 0 }
		end
	end
	for _, raw in ipairs(metrics.playlists or {}) do
		---@cast raw { key: string?, id: number?, count: number?, last: number? }
		if type(raw.id) == "number" then
			self.metrics.playlists[raw.id] = { count = raw.count or 0, last = raw.last or 0 }
		end
	end

	if version == 2 then
		---@type table
		local legacy = type(data.legacy) == "table" and data.legacy or {}
		for _, raw in ipairs(legacy.assignments or {}) do
			if type(raw) == "table" and type(raw.path) == "string" then
				local set = {}
				for _, id in ipairs(raw.tags or {}) do
					if self.tagById[id] ~= nil then set[id] = true end
				end
				if next(set) ~= nil then self.legacy.byPath[raw.path] = set end
			end
		end
		for _, raw in ipairs(legacy.ratings or {}) do
			if type(raw) == "table" and type(raw.path) == "string" and type(raw.value) == "number" then
				local value = clampRating(raw.value)
				if value > 0 then self.legacy.ratings[raw.path] = value end
			end
		end
		for _, raw in ipairs(legacy.tracks or {}) do
			---@cast raw { path: string?, count: number?, last: number? }
			if type(raw.path) == "string" then
				self.legacy.metrics[raw.path] = { count = raw.count or 0, last = raw.last or 0 }
			end
		end
	end

	useTags(self)
	self:ensureTagPlaylists()
	return self
end

return Taxonomy
