-- The words in the bar and the tags narrowing them. The field belongs to the top bar, which sits
-- over every page, so typing anywhere goes to search rather than to the page underneath; and the
-- results are computed over the library, so a new library makes what was typed and picked for the
-- old one meaningless and clears both here.
---
---@class beat.SearchCache
---@field query string
---@field albums beat.Album[]
---@field artists beat.Artist[]
---@field tracks beat.Track[]

---@class beat.SearchService: beat.Service
---@field query string
---@field tagFilter table<number, boolean>
---@field match "all"|"any"
---@field cache beat.SearchCache?
---@field library beat.LibraryService
---@field collections beat.CollectionsService
---@field emit fun(message: table)
local Search = {}
Search.__index = Search
Search.needs = { "library", "collections", "emit" }
Search.handles = {
	"search", "clearSearch", "openSearch",
	"toggleTagFilter", "tagFilterMatch", "clearTagFilter",
}

---@param deps { library: beat.LibraryService, collections: beat.CollectionsService, emit: fun(message: table) }
---@return beat.SearchService
function Search.new(deps)
	local self = setmetatable({
		query = "",
		tagFilter = {},
		match = "all",
		cache = nil,
		library = deps.library,
		collections = deps.collections,
		emit = deps.emit,
	}, Search)

	-- A scan replaces the library with a different set of songs: what was typed and selected for
	-- the old one would keep showing nothing, so the field starts empty again.
	deps.library.replaced:connect(function()
		self.query = ""
		self.tagFilter = {}
		self.cache = nil
	end)
	-- The kept results are the library's answer for a query; a track added or a scan finished
	-- changes that answer, as does a tag that narrows it.
	deps.library.changed:connect(function() self.cache = nil end)
	deps.collections.changed:connect(function()
		self.cache = nil
		-- A deleted tag cannot filter anything, and leaving it selected would hide every track.
		local taxonomy = deps.collections.taxonomy
		for id in pairs(self.tagFilter) do
			if taxonomy.tagById[id] == nil then self.tagFilter[id] = nil end
		end
	end)

	return self
end

--- The query's albums, artists and tracks, narrowed by the selected tags. The library's answer is
--- kept per query -- the tag filter is applied over it, so selecting a tag does not search again --
--- and any library or tag change drops it.
---@return beat.Album[] albums, beat.Artist[] artists, beat.Track[] tracks
function Search:results()
	local library = self.library.current
	if library == nil then return {}, {}, {} end

	local query = self.query
	if self.cache == nil or self.cache.query ~= query then
		local albums, artists, tracks = library:search(query)
		self.cache = { query = query, albums = albums, artists = artists, tracks = tracks}
	end

	local albums, artists, tracks = self.cache.albums, self.cache.artists, self.cache.tracks
	local ids = self:filterIds()
	if #ids == 0 then return albums, artists, tracks end

	local taxonomy = self.collections.taxonomy
	local matchedTracks = {}
	for _, track in ipairs(tracks) do
		if taxonomy:matches(track.path, ids, self.match) then
			matchedTracks[#matchedTracks + 1] = track
		end
	end

	local matchedAlbums = {}
	for _, album in ipairs(albums) do
		local keep = false
		for _, track in ipairs(album.tracks) do
			if taxonomy:matches(track.path, ids, self.match) then keep = true; break end
		end
		if keep then matchedAlbums[#matchedAlbums + 1] = album end
	end

	local matchedArtists = {}
	for _, artist in ipairs(artists) do
		local keep = false
		for _, track in ipairs(artist.tracks) do
			if taxonomy:matches(track.path, ids, self.match) then keep = true; break end
		end
		if keep then matchedArtists[#matchedArtists + 1] = artist end
	end

	return matchedAlbums, matchedArtists, matchedTracks
end

--- Tags selected on the search screen. Empty means no filtering.
---@return number[]
function Search:filterIds()
	local ids = {}
	for id, on in pairs(self.tagFilter) do
		if on then ids[#ids + 1] = id end
	end
	table.sort(ids)
	return ids
end

--- The search page clears the field itself when Escape is pressed before it leaves.
function Search:clear()
	self.query = ""
end

function Search:update(message)
	local kind = message.type
	if kind == "search" then
		self.query = message.value or ""
		-- The field started this navigation. It keeps the keyboard and its caret, so the next
		-- character is typed after the first rather than put in front of it; navigating to the
		-- page already showing does nothing.
		self.emit({ type = "navigate", page = { kind = "search"}, keepFocus = true})
	elseif kind == "clearSearch" then
		self:clear()
	elseif kind == "openSearch" then
		self.emit({ type = "navigate", page = { kind = "search"}})
		self.emit({ type = "focus", field = "search", at = #self.query})
	elseif kind == "toggleTagFilter" then
		if self.tagFilter[message.id] then self.tagFilter[message.id] = nil
		else self.tagFilter[message.id] = true end
	elseif kind == "tagFilterMatch" then
		self.match = message.value == "any" and "any" or "all"
	elseif kind == "clearTagFilter" then
		self.tagFilter = {}
	end
end

return Search
