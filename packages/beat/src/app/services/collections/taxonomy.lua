-- Tags and playlists. Tags belong to tracks and are what both smart playlists and the search
-- filters are built from; a manual playlist is a hidden tag of its own, so membership has one
-- representation whether the person tagged a song or dragged it into a playlist.
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

---@class beat.Taxonomy
---@field tags beat.Tag[]
---@field tagById table<number, beat.Tag>
---@field tagByName table<string, beat.Tag>
---@field byPath table<string, table<number, boolean>>
---@field playlists beat.Playlist[]
---@field playlistById table<number, beat.Playlist>
---@field nextTagId number
---@field nextPlaylistId number
---@field metrics { tracks: table<string, beat.Metric>, albums: table<string, beat.Metric>, tags: table<number, beat.Metric>, playlists: table<number, beat.Metric> }
local Taxonomy = {}
Taxonomy.__index = Taxonomy

---@return beat.Taxonomy
function Taxonomy.new()
	return setmetatable({
		tags = {},
		tagById = {},
		tagByName = {},
		byPath = {},
		playlists = {},
		playlistById = {},
		nextTagId = 1,
		nextPlaylistId = 1,
		metrics = { tracks = {}, albums = {}, tags = {}, playlists = {}},
	}, Taxonomy)
end

---@param value string?
---@return string
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
	for _, set in pairs(self.byPath) do
		for id in pairs(set) do
			local tag = self.tagById[id]
			if tag ~= nil then tag.count = tag.count + 1 end
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

	local tag = { id = self.nextTagId, name = display, hidden = false, count = 0}
	self.nextTagId = self.nextTagId + 1
	self.tags[#self.tags + 1] = tag
	self.tagById[tag.id] = tag
	self.tagByName[key] = tag

	-- A tag is also a smart playlist: same name, one tag, and maintained by tag assignments.
	local playlist = self:addPlaylist(tag.name, true, { tag.id}, "all", {
		manual = false,
		autoTagId = tag.id,
	})
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
		count = 0,
	}
	self.nextTagId = self.nextTagId + 1
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

---@param path string
---@param tagId number
---@return boolean
function Taxonomy:isTagged(path, tagId)
	local set = self.byPath[path]
	return set ~= nil and set[tagId] == true
end

---@param path string
---@param tagId number
---@param on boolean
function Taxonomy:setTag(path, tagId, on)
	if self.tagById[tagId] == nil then return end
	local set = self.byPath[path]
	if on then
		if set == nil then
			set = {}
			self.byPath[path] = set
		end
		if not set[tagId] then
			set[tagId] = true
			local tag = self.tagById[tagId]
			if tag ~= nil then tag.count = tag.count + 1 end
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
		for _ in pairs(set) do empty = false; break end
		if empty then self.byPath[path] = nil end
	end
end

---@param path string
---@param tagId number
---@return boolean state
function Taxonomy:toggleTag(path, tagId)
	local on = not self:isTagged(path, tagId)
	self:setTag(path, tagId, on)
	return on
end

---@param path string
---@param tagIds number[]
---@param match "all"|"any"
---@return boolean
function Taxonomy:matches(path, tagIds, match)
	if #tagIds == 0 then return false end
	local set = self.byPath[path]
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
		match = match == "any" and "any" or "all",
		manual = opts.manual ~= false,
		autoTagId = opts.autoTagId,
		updatedAt = opts.now or os.time(),
	}
	self.nextPlaylistId = self.nextPlaylistId + 1

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
		local smartMatch = playlist.smart and self:matches(track.path, playlist.tagIds, playlist.match)
		local manualMatch = playlist.manual and playlist.hiddenTagId ~= nil
		and self:isTagged(track.path, playlist.hiddenTagId)
		if smartMatch or manualMatch then tracks[#tracks + 1] = track end
	end
	return tracks
end

---@param playlist beat.Playlist
---@param path string
---@param on boolean
function Taxonomy:setPlaylistTrack(playlist, path, on)
	local hidden = playlist.hiddenTagId
	if hidden == nil then return end
	local was = self:isTagged(path, hidden)
	if was ~= on then
		playlist.updatedAt = os.time()
		if on then playlist.manual = true end
		self:setTag(path, hidden, on)
	end
end

---@param playlist beat.Playlist
---@param album beat.Album
---@param on boolean?
function Taxonomy:setPlaylistAlbum(playlist, album, on)
	if on == false then
		for _, track in ipairs(album.tracks) do self:setPlaylistTrack(playlist, track.path, false) end
	else
		for _, track in ipairs(album.tracks) do self:setPlaylistTrack(playlist, track.path, true) end
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
	for path, set in pairs(self.byPath) do
		if set[tagId] then
			set[tagId] = nil
			local empty = true
			for _ in pairs(set) do empty = false; break end
			if empty then self.byPath[path] = nil end
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
				if playlist.autoTagId == tag.id then found = true; break end
			end
			if not found then
				local playlist = self:addPlaylist(tag.name, true, { tag.id}, "all", {
					manual = false,
					autoTagId = tag.id,
				})
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
		metric = { count = 0, last = 0}
		map[key] = metric
	end
	metric.count = metric.count + 1
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
	bump(self.metrics.tracks, track.path, now)
	local album = library:album(track.albumId)
	if album ~= nil then bump(self.metrics.albums, album.key, now) end
	local set = self.byPath[track.path]
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
	return self.metrics.tracks[track.path]
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
		if metric ~= nil then entries[#entries + 1] = { album = album, last = metric.last} end
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

--- What is written to disk. Paths identify tracks across scans; numeric tag ids keep the
--- definitions stable even if a file is renamed later.
---@return table
function Taxonomy:pack()
	local tags = {}
	for _, tag in ipairs(self.tags) do
		tags[#tags + 1] = {
			id = tag.id,
			name = tag.name,
			hidden = tag.hidden == true,
			playlistId = tag.playlistId,
		}
	end

	local assignments = {}
	for path, set in pairs(self.byPath) do
		local ids = {}
		for id in pairs(set) do ids[#ids + 1] = id end
		table.sort(ids)
		assignments[#assignments + 1] = { path = path, tags = ids}
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
			updatedAt = playlist.updatedAt or 0,
		}
	end

	local metrics = { tracks = {}, albums = {}, tags = {}, playlists = {}}
	for key, metric in pairs(self.metrics.tracks) do
		metrics.tracks[#metrics.tracks + 1] = { key = key, count = metric.count, last = metric.last}
	end
	for key, metric in pairs(self.metrics.albums) do
		metrics.albums[#metrics.albums + 1] = { key = key, count = metric.count, last = metric.last}
	end
	for id, metric in pairs(self.metrics.tags) do
		metrics.tags[#metrics.tags + 1] = { id = id, count = metric.count, last = metric.last}
	end
	for id, metric in pairs(self.metrics.playlists) do
		metrics.playlists[#metrics.playlists + 1] = { id = id, count = metric.count, last = metric.last}
	end

	return {
		version = 1,
		tags = tags,
		assignments = assignments,
		playlists = playlists,
		metrics = metrics,
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
				count = 0,
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
				match = raw.match == "any" and "any" or "all",
				manual = raw.manual ~= nil and raw.manual == true or (raw.smart ~= true),
				hiddenTagId = type(raw.hiddenTagId) == "number" and raw.hiddenTagId or nil,
				autoTagId = type(raw.autoTagId) == "number" and raw.autoTagId or nil,
				updatedAt = type(raw.updatedAt) == "number" and raw.updatedAt or 0,
			}
			if playlist.hiddenTagId == nil or self.tagById[playlist.hiddenTagId] == nil then
				playlist.hiddenTagId = self:addHiddenPlaylistTag(playlist.id).id
			end
			self.playlists[#self.playlists + 1] = playlist
			self.playlistById[playlist.id] = playlist
			if playlist.id >= self.nextPlaylistId then self.nextPlaylistId = playlist.id + 1 end
		end
	end
	for _, raw in ipairs(data.assignments or {}) do
		if type(raw) == "table" and type(raw.path) == "string" then
			local set = {}
			for _, id in ipairs(raw.tags or {}) do
				if self.tagById[id] ~= nil then set[id] = true end
			end
			if next(set) ~= nil then self.byPath[raw.path] = set end
		end
	end
	---@type { tracks: any[], albums: any[], tags: any[], playlists: any[] }
	local metrics = data.metrics or {}
	for _, raw in ipairs(metrics.tracks or {}) do
		---@cast raw { key: string?, id: number?, count: number?, last: number? }
		if type(raw.key) == "string" then
			self.metrics.tracks[raw.key] = { count = raw.count or 0, last = raw.last or 0}
		end
	end
	for _, raw in ipairs(metrics.albums or {}) do
		---@cast raw { key: string?, id: number?, count: number?, last: number? }
		if type(raw.key) == "string" then
			self.metrics.albums[raw.key] = { count = raw.count or 0, last = raw.last or 0}
		end
	end
	for _, raw in ipairs(metrics.tags or {}) do
		---@cast raw { key: string?, id: number?, count: number?, last: number? }
		if type(raw.id) == "number" then
			self.metrics.tags[raw.id] = { count = raw.count or 0, last = raw.last or 0}
		end
	end
	for _, raw in ipairs(metrics.playlists or {}) do
		---@cast raw { key: string?, id: number?, count: number?, last: number? }
		if type(raw.id) == "number" then
			self.metrics.playlists[raw.id] = { count = raw.count or 0, last = raw.last or 0}
		end
	end
	useTags(self)
	self:ensureTagPlaylists()
	return self
end

return Taxonomy
