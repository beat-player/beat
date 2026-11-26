-- Tags and playlists: the listener's own organisation of a library that scanning may replace
-- under it. They are keyed by a track key -- a fingerprint of the audio where the scan has one --
-- and saved beside settings rather than in the scan cache, so a rescan keeps them; this is the one
-- place that writes them, and everything that shows them hears about a change here rather than
-- being told to redraw.
local names = require("beat.music.names")
local TagStore = require("beat.app.services.collections.store")
local Signal = require("beat.app.signal")
local time = require("wonderland.time")

-- Each track start bumps a play count and each rating a star, and both land in tags.json. A run of
-- them -- skipping through an album, tapping a few stars -- rewrites the whole file each time, so
-- the write waits until the hand has been still for a moment; a structural edit (a tag, a playlist)
-- still writes at once, because the listener watches for its result.
local SAVE_DELAY = 2

---@class beat.CollectionsService: beat.Service
---@field taxonomy beat.Taxonomy
---@field library beat.LibraryService
---@field toasts beat.ToastsService
---@field changed beat.Signal # Fired after tags or playlists changed and were written
---@field dirtyAt number? # When the deferred tags.json write is due; nil when disk has the current taxonomy
---@field playlistTracksCache table<beat.Playlist, beat.CollectionsService.PlaylistTracksEntry> # By the playlist itself: its id is a number, and a table keyed by both the positive ids and the built-in lists' negative ones is mixed, which the trace compiler will not index
---@field recentPlaylistsCache beat.CollectionsService.RecentPlaylistsEntry?
local Collections = {}
Collections.__index = Collections
Collections.needs = { "library", "toasts" }

--- One playlist's tracks as they were when the taxonomy and library last changed. The array is
--- the cache's own and every caller gets the same one, so a caller only reads it: playback's
--- queue copies what it is started with.
---@class beat.CollectionsService.PlaylistTracksEntry
---@field tracks beat.Track[]
---@field taxonomy beat.Taxonomy
---@field revision number
---@field library beat.Library
---@field version number

--- The recent order as it was at one taxonomy revision.
---@class beat.CollectionsService.RecentPlaylistsEntry
---@field list beat.Playlist[]
---@field taxonomy beat.Taxonomy
---@field revision number

---@param deps { library: beat.LibraryService, toasts: beat.ToastsService }
---@return beat.CollectionsService
function Collections.new(deps)
	local self = setmetatable({
		taxonomy = TagStore.load(),
		library = deps.library,
		toasts = deps.toasts,
		changed = Signal.new(),
		dirtyAt = nil,
		playlistTracksCache = {},
		recentPlaylistsCache = nil
	}, Collections)

	-- The cache loaded at start is a library the tags from a version-1 file can be claimed against
	-- before anything draws. A scan starts from an empty library and its tracks arrive one at a
	-- time, so adoption waits for its end (`finished`) rather than writing tags.json per track; a
	-- library replacing the old one is adopted at once in case it came with tracks already.
	self:adopt(deps.library.current)
	deps.library.replaced:connect(|library| -> self:adopt(library))
	deps.library.finished:connect(|library| -> self:adopt(library))

	return self
end

--- Files the version-1 entries whose path this library holds under their track's key, and writes
--- the taxonomy when that moved anything: an adoption that was not saved would be done again on the
--- next launch.
---@param library beat.Library?
function Collections:adopt(library)
	if library == nil then return end
	-- A library being replaced drops what was derived from the old one even where the taxonomy did
	-- not move: the cached arrays would otherwise keep its tracks alive until each playlist's row
	-- was drawn again.
	self.playlistTracksCache = {}
	if self.taxonomy:adopt(library) then self:save() end
end

--- Writes the taxonomy. A read-only config directory must not take the screen, so the failure is
--- a toast; listeners are told only once disk agrees with memory.
function Collections:save()
	self.dirtyAt = nil
	local ok = TagStore.save(self.taxonomy)
	if not ok then
		self.toasts:show("Could not save tags", "error")
		return
	end
	self.changed:fire()
end

--- A change that can wait: a play count or a rating, which come in runs. The write happens in
--- `step` once the last of them is `SAVE_DELAY` old.
function Collections:saveLater()
	self.dirtyAt = time.now() + SAVE_DELAY
end

---@param now number
---@return boolean changed
---@return boolean|number busy
function Collections:step(now)
	local dirtyAt = self.dirtyAt
	if dirtyAt == nil then return false, false end
	if now >= dirtyAt then
		self:save()
		return false, false
	end
	return false, dirtyAt - now
end

--- The window is closing: a write still settling happens now rather than being lost.
function Collections:flush()
	if self.dirtyAt ~= nil then self:save() end
end

-- The app is being set up again: the taxonomy in memory may be the only thing that has the last
-- play counts, so it is written before the service is dropped.
function Collections:close()
	self:flush()
end

--- Removes a tag and its automatic playlist. The caller draws the frame; a used tag comes here
--- only after the confirmation dialog, because its removal takes tracks out of a playlist.
---@param tagId number
function Collections:deleteTag(tagId)
	local tag = self.taxonomy.tagById[tagId]
	if tag == nil then return end
	self.taxonomy:removeTag(tagId)
	self:save()
	self.toasts:show("Tag deleted · " .. tag.name)
end

--- Removes a playlist and the hidden tag that holds its hand-added tracks. The tag definitions
--- themselves are untouched. A page showing the playlist draws its not-found state from the
--- taxonomy on the next frame; the overlay that asked closes itself.
---@param playlistId number
function Collections:deletePlaylist(playlistId)
	local playlist = self.taxonomy:playlist(playlistId)
	if playlist == nil or playlist.builtin then return end
	self.taxonomy:removePlaylist(playlistId)
	self:save()
	self.toasts:show("Playlist deleted · " .. playlist.name)
end

Collections.on = {
	--- The playlist menu's one entry arrives as a message rather than a call, because the menu is
	--- a list of actions now. The overlay that sent it is light and closes as the message passes.
	---@param self beat.CollectionsService
	---@param message beat.DeletePlaylistMessage
	deletePlaylist = function(self, message) self:deletePlaylist(message.id) end,
	---@param self beat.CollectionsService
	---@param message beat.RateTrackMessage
	rateTrack = function(self, message)
		local library = self.library.current
		local track = library ~= nil and library:track(message.id) or nil
		if track then
			self.taxonomy:setRating(names.trackKey(track), message.stars)
			self:saveLater()
		end
	end,
	---@param self beat.CollectionsService
	---@param message beat.RateAlbumMessage
	rateAlbum = function(self, message)
		local library = self.library.current
		local album = library ~= nil and library:album(message.id) or nil
		if album then
			self.taxonomy:setAlbumRating(album.key, message.stars)
			self:saveLater()
		end
	end
}

--- The tracks a playlist holds, in library order. Built from the library showing: a track it does
--- not hold cannot be played, so it is not here either. The walk is kept until the taxonomy or the
--- library changes (the sidebar asks on every frame); the array is shared, so callers only read it.
---@param playlist beat.Playlist
---@return beat.Track[]
function Collections:playlistTracks(playlist)
	local library = self.library.current
	if library == nil then return {} end

	local taxonomy = self.taxonomy
	local entry = self.playlistTracksCache[playlist]
	if entry == nil or entry.taxonomy ~= taxonomy or entry.revision ~= taxonomy.revision or entry.library ~= library or entry.version ~= library.version then
		entry = {
			tracks = taxonomy:playlistTracks(playlist, library),
			taxonomy = taxonomy,
			revision = taxonomy.revision,
			library = library,
			version = library.version
		}
		self.playlistTracksCache[playlist] = entry
	end

	return entry.tracks
end

--- A playlist and the numbers its order is made of, so the sort never folds a name again.
---@class beat.CollectionsService.RecentPlaylistOrder
---@field playlist beat.Playlist
---@field last number
---@field edited number
---@field name string

---@param a beat.CollectionsService.RecentPlaylistOrder
---@param b beat.CollectionsService.RecentPlaylistOrder
local function recentPlaylistOrder(a, b)
	if a.last ~= b.last then return a.last > b.last end
	if a.edited ~= b.edited then return a.edited > b.edited end
	return a.name < b.name
end

--- Playlists a sidebar shortcut can show, most recently played first. Plays are what order
--- them; a playlist never played but recently edited still beats an older one, and the name
--- breaks the remaining ties so the order does not wander between frames. Sorted once per
--- taxonomy revision rather than once per frame.
---@param limit number?
---@return beat.Playlist[]
function Collections:recentPlaylists(limit)
	local taxonomy = self.taxonomy
	local cache = self.recentPlaylistsCache
	if cache == nil or cache.taxonomy ~= taxonomy or cache.revision ~= taxonomy.revision then
		local plays = taxonomy.metrics.playlists
		local entries = {}
		for _, playlist in ipairs(taxonomy.playlists) do
			local metric = plays[playlist.id]
			entries[#entries + 1] = {
				playlist = playlist,
				last = metric?.last or 0,
				edited = playlist.updatedAt or 0,
				name = names.fold(playlist.name)
			}
		end
		table.sort(entries, recentPlaylistOrder)
		local list = {}
		for at = 1, #entries do list[at] = entries[at].playlist end
		cache = { list = list, taxonomy = taxonomy, revision = taxonomy.revision }
		self.recentPlaylistsCache = cache
	end

	local sorted = cache.list
	local count = limit ~= nil and math.min(limit, #sorted) or #sorted
	local list = {}
	for at = 1, count do list[at] = sorted[at] end
	return list
end

--- A listen counts towards the playlist it was started from, the album it is on and its tags.
--- Written after the hand settles: every track start would otherwise rewrite the whole file.
---@param track beat.Track
---@param playlistId number?
---@param at number?
function Collections:recordListen(track, playlistId, at)
	self.taxonomy:recordListen(track, assert(self.library.current), playlistId, at)
	self:saveLater()
end

return Collections
