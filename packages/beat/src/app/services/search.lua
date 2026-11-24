-- The words in the bar and the tags narrowing them. The field belongs to the top bar, which sits
-- over every page, so typing anywhere goes to search rather than to the page underneath; and the
-- results are computed over the library, so a new library makes what was typed and picked for the
-- old one meaningless and clears both here.
local names = require("beat.music.names")
---
---@class beat.SearchCache
---@field query string
---@field filter string # The selected tags' ids, sorted and joined: any change to the selection is a miss
---@field match "all"|"any"
---@field version number # The library version the lists answer
---@field taxonomy beat.Taxonomy # The tags the filtered lists were narrowed with
---@field revision number # That taxonomy's revision, which every tag change bumps
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
		emit = deps.emit
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

--- The query's albums, artists and tracks, narrowed by the selected tags. Everything the answer
--- depends on is part of the key -- the query, the selected tags, how they combine and the library
--- version -- so a frame that changes none of them reads the lists the last frame did instead of
--- walking the tracks again. The library's own answer is kept per query, so selecting a tag does
--- not search again, and any library or tag change drops the cache.
---@return beat.Album[] albums, beat.Artist[] artists, beat.Track[] tracks
function Search:results()
	local library = self.library.current
	if library == nil then return {}, {}, {} end

	local ids = self:filterIds()
	local filter = #ids == 0 ? "" : table.concat(ids, ",")
	local taxonomy = self.collections.taxonomy
	local cache = self.cache
	if cache ~= nil and cache.query == self.query and cache.filter == filter and cache.match == self.match and cache.version == library.version and cache.taxonomy == taxonomy and cache.revision == taxonomy.revision then
		return cache.albums, cache.artists, cache.tracks
	end

	local albums, artists, tracks = library:search(self.query)
	if #ids > 0 then
		local matchedTracks = {}
		for _, track in ipairs(tracks) do
			if taxonomy:matches(names.trackKey(track), ids, self.match) then
				matchedTracks[#matchedTracks + 1] = track
			end
		end

		local matchedAlbums = {}
		for _, album in ipairs(albums) do
			local keep = false
			for _, track in ipairs(album.tracks) do
				if taxonomy:matches(names.trackKey(track), ids, self.match) then
					keep = true
					break
				end
			end
			if keep then matchedAlbums[#matchedAlbums + 1] = album end
		end

		local matchedArtists = {}
		for _, artist in ipairs(artists) do
			local keep = false
			for _, track in ipairs(artist.tracks) do
				if taxonomy:matches(names.trackKey(track), ids, self.match) then
					keep = true
					break
				end
			end
			if keep then matchedArtists[#matchedArtists + 1] = artist end
		end

		albums, artists, tracks = matchedAlbums, matchedArtists, matchedTracks
	end

	self.cache = {
		query = self.query,
		filter = filter,
		match = self.match,
		version = library.version,
		taxonomy = taxonomy,
		revision = taxonomy.revision,
		albums = albums,
		artists = artists,
		tracks = tracks
	}
	return albums, artists, tracks
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

--- Gives back the folded text the last query built. The pages draw nothing while the field is
--- empty, and the text is a few hundred kilobytes of strings kept for a search nobody is looking
--- at; the next query makes it again in one pass over the library.
function Search:releaseIndex()
	local library = self.library.current
	if library ~= nil and library.sweep ~= nil then library:forgetSearch() end
end

--- The search page clears the field itself when Escape is pressed before it leaves.
function Search:clear()
	self.query = ""
	self:releaseIndex()
end

--- The bar and the tag chips on the search screen.
Search.on = {
	--- The field started this navigation. It keeps the keyboard and its caret, so the next
	--- character is typed after the first rather than put in front of it; navigating to the page
	--- already showing does nothing.
	---@param self beat.SearchService
	---@param message beat.SearchMessage
	search = function(self, message)
		self.query = message.value or ""
		-- Typing back to an empty field is the other way a query stops reading the text.
		if self.query == "" then self:releaseIndex() end
		self.emit({ type = "navigate", page = { kind = "search" }, keepFocus = true })
	end,
	---@param self beat.SearchService
	---@param message beat.ClearSearchMessage
	clearSearch = function(self, message) self:clear() end,
	---@param self beat.SearchService
	---@param message beat.OpenSearchMessage
	openSearch = function(self, message)
		self.emit({ type = "navigate", page = { kind = "search" } })
		self.emit({ type = "focus", field = "search", at = #self.query })
	end,
	---@param self beat.SearchService
	---@param message beat.ToggleTagFilterMessage
	toggleTagFilter = function(self, message)
		if self.tagFilter[message.id] then
			self.tagFilter[message.id] = nil
		else
			self.tagFilter[message.id] = true
		end
	end,
	---@param self beat.SearchService
	---@param message beat.TagFilterMatchMessage
	tagFilterMatch = function(self, message) self.match = message.value == "any" ? "any" : "all" end,
	---@param self beat.SearchService
	---@param message beat.ClearTagFilterMessage
	clearTagFilter = function(self, message) self.tagFilter = {} end
}

return Search
