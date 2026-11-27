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
---@field itemTagsCache table<beat.Album|beat.Track, beat.CollectionsService.ItemTagsEntry> # By the item: the tags it carries, so a picker asks once
---@field playlistKeysCache table<beat.Playlist, beat.CollectionsService.PlaylistKeysEntry> # By the playlist: the track keys it holds
local Collections = {}
Collections.__index = Collections
Collections.needs = { "library", "toasts", "options" }

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

--- The tags an item carries at one taxonomy revision. An album's set is the intersection of its
--- tracks' tags, which is what its check means.
---@class beat.CollectionsService.ItemTagsEntry
---@field tags table<number, boolean>
---@field taxonomy beat.Taxonomy
---@field revision number
---@field library beat.Library
---@field version number

--- The track keys a playlist holds at one taxonomy revision: its hidden tag's members, read as a
--- set so a row asks whether its track is in it rather than walking the tag map.
---@class beat.CollectionsService.PlaylistKeysEntry
---@field keys table<string, boolean>
---@field taxonomy beat.Taxonomy
---@field revision number

-- Answers a frame reads rather than new empty tables: an item with no tags and a playlist holding
-- nothing. Callers only read them.
local NO_TAGS = {}
local NO_KEYS = {}

---@param deps { library: beat.LibraryService, toasts: beat.ToastsService, options: { taxonomy: beat.Taxonomy? }? }
---@return beat.CollectionsService
function Collections.new(deps)
	local reused = deps.options ~= nil and deps.options.taxonomy or nil
	local self = setmetatable({
		taxonomy = reused or TagStore.load(),
		library = deps.library,
		toasts = deps.toasts,
		changed = Signal.new(),
		dirtyAt = nil,
		playlistTracksCache = {},
		recentPlaylistsCache = nil,
		itemTagsCache = setmetatable({}, { __mode = "k" }),
		playlistKeysCache = setmetatable({}, { __mode = "k" })
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
	self.itemTagsCache = setmetatable({}, { __mode = "k" })
	self.playlistKeysCache = setmetatable({}, { __mode = "k" })
	if self.taxonomy:adopt(library) then self:save() end
end

--- Writes the taxonomy. A read-only config directory must not take the screen, so the failure is
--- a toast. The document is encoded here, where it is small, and written on a thread of its own,
--- so the toggle that asked for it does not hold the frame drawing its check; listeners are told
--- as the write starts, and `TagStore.load` or a flush waits for the file to agree.
function Collections:save()
	self.dirtyAt = nil
	local ok = TagStore.saveAsync(self.taxonomy)
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

--- The window is closing: a write still settling happens now rather than being lost. A deferred
--- change is written synchronously; a threaded write already in flight is joined.
function Collections:flush()
	if self.dirtyAt ~= nil then
		self.dirtyAt = nil
		local ok = TagStore.save(self.taxonomy)
		if not ok then
			self.toasts:show("Could not save tags", "error")
			return
		end
		self.changed:fire()
		return
	end
	TagStore.flush()
end

-- The app is being set up again: the taxonomy in memory may be the only thing that has the last
-- play counts, so it is written before the service is dropped.
function Collections:close()
	self:flush()
end

--- The tags an item carries, as a set read from the taxonomy once per revision: an album's set is
--- every tag all of its tracks carry, so the picker's row check is one lookup rather than a walk of
--- the album for every tag it lists. The sets are derived state, so they are kept until the
--- taxonomy or the library changes and are not written anywhere.
---@param kind "track"|"album"|string
---@param id number
---@return table<number, boolean>
function Collections:itemTagSet(kind, id)
	local library = self.library.current
	if library == nil then return NO_TAGS end
	local item = kind == "album" and library:album(id) or library:track(id)
	if item == nil then return NO_TAGS end

	local taxonomy = self.taxonomy
	local entry = self.itemTagsCache[item]
	if
		entry ~= nil
		and entry.taxonomy == taxonomy
		and entry.revision == taxonomy.revision
		and entry.library == library
		and entry.version == library.version
	then
		return entry.tags
	end

	local tags = {}
	local byKey = taxonomy.byKey
	if kind == "album" then
		local tracks = item.tracks
		local count = #tracks
		if count > 0 then
			local first = byKey[names.trackKey(tracks[1])]
			if first ~= nil then
				for tagId in pairs(first) do tags[tagId] = true end
				for at = 2, count do
					local set = byKey[names.trackKey(tracks[at])]
					if set == nil then
						tags = {}
						break
					end
					for tagId in pairs(tags) do
						if set[tagId] ~= true then tags[tagId] = nil end
					end
					if next(tags) == nil then break end
				end
			end
		end
	else
		local set = byKey[names.trackKey(item)]
		if set ~= nil then
			for tagId in pairs(set) do tags[tagId] = true end
		end
	end

	entry = {
		tags = tags,
		taxonomy = taxonomy,
		revision = taxonomy.revision,
		library = library,
		version = library.version
	}
	self.itemTagsCache[item] = entry
	return tags
end

--- The track keys a playlist holds, as a set, built once per taxonomy revision: a windowed list
--- asks for the same membership on every frame, and an album asks about each of its tracks. The
--- hidden tag is the manual membership, so the keys are read from the tag map rather than from the
--- library. The set is the cache's own, so a caller only reads it.
---@param playlist beat.Playlist
---@return table<string, boolean>
function Collections:playlistKeySet(playlist)
	local taxonomy = self.taxonomy
	local entry = self.playlistKeysCache[playlist]
	if entry ~= nil and entry.taxonomy == taxonomy and entry.revision == taxonomy.revision then
		return entry.keys
	end

	local keys = {}
	local hidden = playlist.hiddenTagId
	if hidden ~= nil then
		for key, set in pairs(taxonomy.byKey) do
			if set[hidden] == true then keys[key] = true end
		end
	end
	entry = { keys = keys, taxonomy = taxonomy, revision = taxonomy.revision }
	self.playlistKeysCache[playlist] = entry
	return keys
end

--- Whether an item carries a tag. An album carries it when every track on it does: that is what
--- the picker's check means for an album, and a toggle takes away exactly what the check promised.
---@param kind "track"|"album"|string
---@param id number
---@param tagId number
---@return boolean
function Collections:itemHasTag(kind, id, tagId)
	return self:itemTagSet(kind, id)[tagId] == true
end

--- Puts a tag on every track an item is, or takes it off every one. An album whose tracks do not
--- all carry it gains it on all of them; one that does loses it on all. The caller writes, because
--- a create and the tagging it came with are one change to disk.
---@param kind "track"|"album"|string
---@param id number
---@param tagId number
---@param on boolean
---@return number changed # How many tracks the tag was put on or taken off
function Collections:setItemTag(kind, id, tagId, on)
	local library = self.library.current
	local taxonomy = self.taxonomy
	if library == nil or taxonomy.tagById[tagId] == nil then return 0 end
	local changed = 0
	if kind == "album" then
		local album = library:album(id)
		if album == nil then return 0 end
		local tracks = album.tracks
		for at = 1, #tracks do
			local key = names.trackKey(tracks[at])
			if taxonomy:isTagged(key, tagId) ~= on then
				taxonomy:setTag(key, tagId, on)
				changed += 1
			end
		end
	else
		local track = library:track(id)
		if track == nil then return 0 end
		local key = names.trackKey(track)
		if taxonomy:isTagged(key, tagId) ~= on then
			taxonomy:setTag(key, tagId, on)
			changed = 1
		end
	end
	return changed
end

--- Turns a tag on or off for the whole item, in one press. Saved at once, because the listener
--- watches the check appear in the row they just pressed.
---@param kind "track"|"album"|string
---@param id number
---@param tagId number
---@return boolean on # Whether the item carries it now
function Collections:toggleItemTag(kind, id, tagId)
	local on = not self:itemHasTag(kind, id, tagId)
	self:setItemTag(kind, id, tagId, on)
	self:save()
	return on
end

--- Makes a tag and, when the picker it was made in was for an item, puts it on that item in the
--- same step: the listener named a tag from a track or album, so the tag starts on it rather than
--- waiting to be pressed a second time. Saved once either way.
---@param name string
---@param kind "track"|"album"|string?
---@param id number?
---@return beat.Tag? tag
---@return boolean applied
function Collections:createTag(name, kind, id)
	local tag = self.taxonomy:addTag(name)
	if tag == nil then return nil, false end
	local applied = kind ~= nil and id ~= nil and self:setItemTag(kind, id, tag.id, true) > 0
	self:save()
	return tag, applied
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

--- Takes one row out of a manual playlist. `index` names the track the page listed; a manual
--- playlist is a set of track keys, so that track's key is what leaves. A smart list is its tag
--- rules and a built-in is computed from the library, so neither accepts a hand removal. The
--- write is immediate, because the listener watches the row go and may undo it.
---@param playlistId number
---@param index number
---@return beat.Track? removed
function Collections:removePlaylistTrack(playlistId, index)
	local playlist = self.taxonomy:playlist(playlistId)
	if playlist == nil or playlist.builtin or playlist.smart or not playlist.manual then return nil end
	local track = self:playlistTracks(playlist)[index]
	if track == nil then return nil end
	self.taxonomy:setPlaylistTrack(playlist, names.trackKey(track), false)
	self:save()
	self.toasts:show("Removed from " .. playlist.name)
	return track
end

--- Puts a removed track back, which is what the toast's undo sends. A manual playlist lists its
--- tracks in library order, so the key it left by returns to the same row without one stored. The
--- message also carries that row's index for an undo control to name it; the row is where the
--- track's place in the library puts it, not a second order to keep in step.
---@param playlistId number
---@param trackId number
---@return beat.Track? restored
function Collections:restorePlaylistTrack(playlistId, trackId)
	local playlist = self.taxonomy:playlist(playlistId)
	local library = self.library.current
	local track = library ~= nil and library:track(trackId) or nil
	if playlist == nil or track == nil or playlist.builtin or playlist.smart or not playlist.manual then return nil end
	self.taxonomy:setPlaylistTrack(playlist, names.trackKey(track), true)
	self:save()
	return track
end

Collections.on = {
	--- The playlist menu's one entry arrives as a message rather than a call, because the menu is
	--- a list of actions now. The overlay that sent it is light and closes as the message passes.
	---@param self beat.CollectionsService
	---@param message beat.DeletePlaylistMessage
	deletePlaylist = function(self, message) self:deletePlaylist(message.id) end,
	--- A row's own menu entry names the playlist and the row it was opened on, so exactly the
	--- occurrence the listener pointed at leaves.
	---@param self beat.CollectionsService
	---@param message beat.PlaylistRemoveMessage
	playlistRemove = function(self, message) self:removePlaylistTrack(message.playlist, message.index) end,
	--- The undo half of the same entry. A toast action would send this; the toast service has no
	--- actions yet, so nothing in the screen sends it today.
	---@param self beat.CollectionsService
	---@param message beat.PlaylistRestoreMessage
	playlistRestore = function(self, message)
		self:restorePlaylistTrack(message.playlist, message.id)
	end,
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
