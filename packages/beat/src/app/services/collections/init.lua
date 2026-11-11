-- Tags and playlists: the listener's own organisation of a library that scanning may replace
-- under it. They are keyed by a track key -- a fingerprint of the audio where the scan has one --
-- and saved beside settings rather than in the scan cache, so a rescan keeps them; this is the one
-- place that writes them, and everything that shows them hears about a change here rather than
-- being told to redraw.
local names = require("beat.music.names")
local TagStore = require("beat.app.services.collections.store")
local Signal = require("beat.app.signal")

---@class beat.CollectionsService: beat.Service
---@field taxonomy beat.Taxonomy
---@field library beat.LibraryService
---@field toasts beat.ToastsService
---@field changed beat.Signal # Fired after tags or playlists changed and were written
local Collections = {}
Collections.__index = Collections
Collections.needs = { "library", "toasts" }

---@param deps { library: beat.LibraryService, toasts: beat.ToastsService }
---@return beat.CollectionsService
function Collections.new(deps)
	local self = setmetatable(
		{
			taxonomy = TagStore.load(),
			library = deps.library,
			toasts = deps.toasts,
			changed = Signal.new()
		},
		Collections
	)

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
	if library ~= nil and self.taxonomy:adopt(library) then self:save() end
end

--- Writes the taxonomy. A read-only config directory must not take the screen, so the failure is
--- a toast; listeners are told only once disk agrees with memory.
function Collections:save()
	local ok = TagStore.save(self.taxonomy)
	if not ok then
		self.toasts:show("Could not save tags", "error")
		return
	end
	self.changed:fire()
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
	if playlist == nil then return end
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
			self:save()
		end
	end,

	---@param self beat.CollectionsService
	---@param message beat.RateAlbumMessage
	rateAlbum = function(self, message)
		local library = self.library.current
		local album = library ~= nil and library:album(message.id) or nil
		if album then
			self.taxonomy:setAlbumRating(album.key, message.stars)
			self:save()
		end
	end
}

--- The tracks a playlist holds, in library order. Built from the library showing: a track it does
--- not hold cannot be played, so it is not here either.
---@param playlist beat.Playlist
---@return beat.Track[]
function Collections:playlistTracks(playlist)
	local library = self.library.current
	if library == nil then return {} end
	return self.taxonomy:playlistTracks(playlist, library)
end

--- Playlists a sidebar shortcut can show, most recently played first. Plays are what order
--- them; a playlist never played but recently edited still beats an older one, and the name
--- breaks the remaining ties so the order does not wander between frames.
---@param limit number?
---@return beat.Playlist[]
function Collections:recentPlaylists(limit)
	local list = {}
	if self.taxonomy == nil then return list end
	for _, playlist in ipairs(self.taxonomy.playlists) do list[#list + 1] = playlist end
	local plays = self.taxonomy.metrics.playlists
	table.sort(list, function(a, b)
		local aMetric = plays[a.id]
		local bMetric = plays[b.id]
		local aLast = aMetric?.last or 0
		local bLast = bMetric?.last or 0
		if aLast ~= bLast then return aLast > bLast end
		local aEdited = a.updatedAt or 0
		local bEdited = b.updatedAt or 0
		if aEdited ~= bEdited then return aEdited > bEdited end
		return a.name:lower() < b.name:lower()
	end)
	if limit ~= nil and #list > limit then
		for at = #list, limit + 1, -1 do list[at] = nil end
	end
	return list
end

--- A listen counts towards the playlist it was started from, the album it is on and its tags.
--- Saved at once: the counts are small and losing the last few on a crash is worse than the write.
---@param track beat.Track
---@param playlistId number?
---@param at number?
function Collections:recordListen(track, playlistId, at)
	self.taxonomy:recordListen(track, assert(self.library.current), playlistId, at)
	self:save()
end

return Collections
