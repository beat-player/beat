local ffi = require("ffi")
local wonderland = require("wonderland")
local core = require("beat-core")
local ui = require("beat-ui")
local fs = require("fs")
local path = require("path")

local Covers = require("beat.app.covers")
local pages = require("beat.app.pages")
local Picker = require("beat.app.picker")
local folders = require("beat.app.folders")
local ScanJob = require("beat.app.scan_job")
local LibraryCache = require("beat.app.library_cache")
local Log = require("beat.app.log")
local LastfmClient = require("beat.app.lastfm")
local TagStore = require("beat.app.tag_store")
local links = require("beat.app.links")

-- Written by build.lua from assets/icon-256.png, so a compiled binary carries it too.
local iconData = require("beat.app.icon")

local time = wonderland.time
local util = core.util

---@alias beat.Page
--- | { kind: "home" }
--- | { kind: "search" }
--- | { kind: "searchAll", category: "albums"|"artists"|"tracks" }
--- | { kind: "library" }
--- | { kind: "settings" }
--- | { kind: "folders" }
--- | { kind: "album", id: number }
--- | { kind: "artist", id: number }
--- | { kind: "playlists" }
--- | { kind: "playlist", id: number }

---@class beat.ContextMenu
---@field id number
---@field x number
---@field y number

---@class beat.App: wonderland.App
---@field settings beat.Settings
---@field window wonderland.RenderWindow?
---@field layoutPlugin wonderland.plugin.Layout?
---@field theme beat.ui.Theme
---@field motion beat.ui.Motion
---@field library beat.Library?
---@field scan beat.ScanJob?
---@field player beat.Player
---@field scrobbler beat.Scrobbler
---@field lastfm beat.LastfmClient
---@field spectrum beat.Spectrum
---@field covers beat.ui.Covers
---@field assets wonderland.Assets?
---@field page beat.Page
---@field history beat.Page[]
---@field future beat.Page[]
---@field search string
---@field scroll table<string, number>
---@field scrollTargets table<string, number>
---@field scrollAnimating boolean
---@field scrollMax number? # The furthest the page built last frame can scroll, where it knows
---@field lastTick number
---@field ticker table?
---@field folderPath string? # nil while the browser lists the drives, on Windows
---@field folderDraft string # What the path field holds, typed or not
---@field folderEntries { name: string, path: string }[]
---@field folderError string?
---@field scanSkipped number
---@field scanErrors { path: string, message: string }[]
---@field folderAsk boolean? # Whether the system folder dialog is to be opened on the next tick
---@field scanIslandOpen boolean
---@field scanSummary { tracks: number, albums: number, skipped: number, at: number }?
---@field expanded boolean
---@field volumeOpen boolean
---@field queueOpen boolean
---@field moreOpen boolean
---@field equalizerOpen boolean
---@field equalizerEdit string?
---@field equalizerEditDraft string
---@field transition { start: number, direction: number? }?
---@field toasts { text: string, tone: string, at: number, expires: number, rect: { x: number, y: number, width: number, height: number }? }[]
---@field themeFade { start: number }?
---@field sortedAlbums beat.Album[]?
---@field sortedFor string?
---@field sortOpen boolean
---@field iconSet boolean
---@field accentPickerOpen boolean
---@field accentDraft string?
---@field contextMenu beat.ContextMenu?
---@field taxonomy beat.Taxonomy
---@field tagPickerOpen boolean
---@field tagDialogOpen boolean
---@field tagDraft string
---@field playlistDialog { smart: boolean, name: string, tagIds: table<number, boolean>, match: "all"|"any" }?
---@field playlistPicker { kind: "album"|"track", id: number }?
---@field trackMenu { id: number, x: number, y: number }?
---@field playlistMenu { id: number, x: number, y: number }?
---@field tagFilter table<number, boolean>
---@field tagFilterMatch "all"|"any"
---@field tagTrackId number?
---@field tagEditId number?
---@field tagEditDraft string
---@field tagDeleteId number?
---@field hoverTagId number?
---@field hoverPlaylist { id: number, y: number, top: number?, x: number?, height: number? }?
---@field playlistAdder { playlistId: number, query: string }?
---@field lastListenedTrackId number?
---@field dirtyAt number?
local App = wonderland.app("Beat")

local HOME = os.getenv("HOME") or os.getenv("USERPROFILE") or "/"

---@param page beat.Page
---@return string
local function keyOf(page)
	if page.kind == "album" then return "album:" .. tostring(page.id) end
	if page.kind == "artist" then return "artist:" .. tostring(page.id) end
	if page.kind == "playlist" then return "playlist:" .. tostring(page.id) end
	if page.kind == "searchAll" then return "searchAll:" .. page.category end
	return page.kind
end

---@param a beat.Page
---@param b beat.Page
---@return boolean
local function samePage(a, b)
	if a.kind == "album" then return b.kind == "album" and a.id == b.id end
	if a.kind == "artist" then return b.kind == "artist" and a.id == b.id end
	if a.kind == "playlist" then return b.kind == "playlist" and a.id == b.id end
	if a.kind == "searchAll" then return b.kind == "searchAll" and a.category == b.category end
	return a.kind == b.kind
end

--- Gives the window the logo as its icon, where the backend can take one. X11 reads it from the
--- `_NET_WM_ICON` property; a backend without `setIcon` leaves the window as it was.
---@param window wonderland.RenderWindow
function App:setIcon(window)
	if self.iconSet or window.setIcon == nil then return end

	local icon = core.art.decodePNG(iconData)
	if icon == nil then return end

	window:setIcon(icon.width, icon.height, ffi.string(icon.pixels, icon.width * icon.height * 4))
	self.iconSet = true
end

---@param opts { scan: boolean? }?
function App:init(opts)
	if self.lastfm ~= nil then self.lastfm:close() end
	self.settings = core.settings.load()
	self.theme = ui.theme.new(self.settings.theme, self.settings.accent, self.settings.uiScale)
	self.motion = ui.motion.new(self.settings.reduceMotion)
	self.player = core.Player.new()
	self.scrobbler = core.Scrobbler.new()
	self.spectrum = core.Spectrum.new()
	self.player.onSamples = function(samples, frames, channels)
		self.spectrum:feed(samples, frames, channels)
	end
	self.player:setVolume(self.settings.volume)
	self.player.isMuted = self.settings.isMuted
	self.player:setEqualizer(core.equalizer.bands(self.settings.equalizerGains))
	self.covers = Covers.new()
	self.taxonomy = TagStore.load()
	self.tagPickerOpen = false
	self.tagDialogOpen = false
	self.tagDraft = ""
	self.playlistDialog = nil
	self.playlistPicker = nil
	self.trackMenu = nil
	self.playlistMenu = nil
	self.tagFilter = {}
	self.tagFilterMatch = "all"
	self.tagTrackId = nil
	self.tagEditId = nil
	self.tagEditDraft = ""
	self.tagDeleteId = nil
	self.hoverTagId = nil
	self.hoverPlaylist = nil
	self.playlistAdder = nil
	self.lastListenedTrackId = nil
	self.folderAsk = nil
	self.scan = nil
	self.library = nil
	self.sortedAlbums = nil
	self.sortedFor = nil
	self.sortOpen = false
	self.scanIslandOpen = true
	self.scanSummary = nil

	self.page = { kind = "home"}
	self.history = {}
	self.future = {}
	self.search = ""
	self.scroll = {}
	self.scrollTargets = {}
	self.scrollAnimating = false
	self.scrollMax = nil
	self.lastTick = time.now()
	self.expanded = false
	self.volumeOpen = false
	self.queueOpen = false
	self.moreOpen = false
	self.equalizerOpen = false
	self.equalizerEdit = nil
	self.equalizerEditDraft = ""
	self.toasts = {}
	self.lastfm = LastfmClient.new(self.settings, {
	onToast = function(text, tone) self:toast(text, tone) end,
	onSave = function() self:saveSettings() end,
	})

	self.motion:set("nowPlaying", 0)

	local start = self.settings.root or HOME
	self.folderPath = start
	self.folderError = nil
	self.scanSkipped = 0
	self.scanErrors = {}
	self:readFolder(start)

	if self.settings.root ~= nil and (opts == nil or opts.scan ~= false) then
		-- The last complete scan is loaded before anything is scanned again, so a launch draws
		-- songs instead of the first-scan page. A manual Rescan replaces it.
		local cached = LibraryCache.load(assert(self.settings.root))
		if cached ~= nil then
			self.library = cached
			self.sortedAlbums = nil
		else
			self:startScan(assert(self.settings.root))
		end
	end

	self.ticker = self:onTick(function(now, window) return self:tick(now, window) end)
end

---@return boolean
function App:needsFolder()
	return self.settings.root == nil
end

--- The in-app folder browser, for platforms without a native dialog. The first-run screen
--- already is that browser. It opens on the current library folder.
function App:browseFolders()
	if self:needsFolder() or self.page.kind == "folders" then return end
	self:readFolder(self.settings.root or HOME)
	self:go({ kind = "folders"})
end

--- Lists a folder in the browser, or the drives with nil. A typed path is taken from the folder
--- shown, and a folder that cannot be read keeps its path so the field can be corrected.
---@param pathname string?
function App:readFolder(pathname)
	self.folderEntries = {}
	self.folderError = nil
	self.scroll.folders = 0

	if pathname == nil then
		self.folderPath = nil
		self.folderDraft = ""
		for _, drive in ipairs(folders.drives()) do
				self.folderEntries[#self.folderEntries + 1] = { name = drive, path = drive}
			end
		return
	end

	local folder = folders.normalize(pathname, self.folderPath or HOME, HOME)
	self.folderPath = folder
	self.folderDraft = folder
	local iterator = fs.readdir(folder)
	if iterator == nil then
		self.folderError = "Cannot read this folder"
		return
	end

	for entry in iterator do
			if entry.type == "dir" and entry.name:sub(1, 1) ~= "." then
				self.folderEntries[#self.folderEntries + 1] = {
				name = entry.name,
				path = folders.join(folder, entry.name),
				}
			end
		end

	table.sort(self.folderEntries, function(a, b) return a.name:lower() < b.name:lower() end)
end

function App:refresh()
	local window = self.window
	if window ~= nil then self:present(window) end
end

function App:saveTaxonomy()
	local ok = TagStore.save(self.taxonomy)
	if not ok then self:toast("Could not save tags", "error") end
end

--- Removes a tag and its automatic playlist from the in-memory state and disk. The caller draws
--- the frame; a used tag comes here only after the confirmation dialog.
---@param tagId number
function App:deleteTag(tagId)
	local tag = self.taxonomy.tagById[tagId]
	if tag == nil then return end
	self.taxonomy:removeTag(tagId)
	self.tagFilter[tagId] = nil
	if self.tagEditId == tagId then
		self.tagEditId = nil
		self.tagEditDraft = ""
		self:focusField(nil)
	end
	if self.tagDeleteId == tagId then self.tagDeleteId = nil end
	if self.hoverTagId == tagId then self.hoverTagId = nil end
	self:saveTaxonomy()
	self:toast("Tag deleted · " .. tag.name)
end

--- Removes a playlist and the hidden tag that holds its hand-added tracks. The page is left
--- alone unless it is showing the playlist that just went away.
---@param playlistId number
function App:deletePlaylist(playlistId)
	local playlist = self.taxonomy:playlist(playlistId)
	if playlist == nil then return end
	self.taxonomy:removePlaylist(playlistId)
	if self.page.kind == "playlist" and self.page.id == playlistId then
		self.page = { kind = "playlists"}
		self.scroll.playlists = 0
	end
	if self.playlistAdder ~= nil and self.playlistAdder.playlistId == playlistId then
		self.playlistAdder = nil
	end
	if self.playlistPicker ~= nil then self.playlistPicker = nil end
	if self.tagDeleteId == playlist.hiddenTagId then self.tagDeleteId = nil end
	if self.hoverPlaylist ~= nil and self.hoverPlaylist.id == playlistId then self.hoverPlaylist = nil end
	self.playlistMenu = nil
	self:saveTaxonomy()
	self:toast("Playlist deleted · " .. playlist.name)
end

--- Put the caret in a dialog's field as soon as it opens, so typing is the next thing that
--- happens rather than a click into the field first.
---@param name string?
---@param at number? # Where the caret starts, at the end of a value that was already typed
function App:focusField(name, at)
	if self.layoutPlugin ~= nil and self.window ~= nil then
		self.layoutPlugin:setFocus(self.window, name)
		if name ~= nil and at ~= nil then
			self.layoutPlugin:setCaret(self.window, 0, at)
		end
	end
end

---@param track beat.Track
---@return boolean
function App:hasAnyTag(track)
	for _, tag in ipairs(self.taxonomy:visibleTags()) do
			if self.taxonomy:isTagged(track.path, tag.id) then return true end
		end
	return false
end

---@param root string
function App:startScan(root)
	self.sortOpen = false
	self.folderAsk = nil
	if self.scan ~= nil then self.scan:cancel() end
	self.player:close()
	self.spectrum:clear()
	self.covers:releaseAll()
	self.library = core.Library.new(root)
	self.sortedAlbums = nil
	self.scan = ScanJob.start(root)
	self.scanIslandOpen = true
	self.scanSummary = nil
	self.tagPickerOpen = false
	self.tagDialogOpen = false
	self.playlistDialog = nil
	self.playlistPicker = nil
	self.playlistAdder = nil
	self.tagEditId = nil
	self.tagDeleteId = nil
	self.hoverTagId = nil
	self.hoverPlaylist = nil
	self.trackMenu = nil
	self.playlistMenu = nil
	self:focusField(nil)
	self.settings.root = root
	self.folderPath = root
	self.page = { kind = "home"}
	self.history = {}
	self.future = {}
	self.search = ""
	self.expanded = false
	self.scanSkipped = 0
	self.scanErrors = {}
	self:saveSettings()
	self:refresh()
end

function App:saveSettings()
	local ok, err = core.settings.save(self.settings, nil)

	if not ok then Log.write("error", "settings could not be saved: " .. tostring(err)) end

	self.dirtyAt = nil
end

function App:markSettingsDirty()
	self.dirtyAt = time.now() + 0.6
end

---@param text string
---@param tone string?
function App:toast(text, tone)
	local now = time.now()
	tone = tone or "info"

	self.toasts[#self.toasts + 1] = {
		text = text,
		tone = tone,
		at = now,
		expires = now + (tone == "error" and 8 or 4.5),
	}
	if #self.toasts > 3 then table.remove(self.toasts, 1) end

	if tone == "error" then Log.write("error", text) end

	self:wake()
end

---@return number
function App:scrollOffset(key)
	return self.scroll[key] or 0
end

---@return string
function App:pageKey()
	return keyOf(self.page)
end

---@return string
function App:pageTitle()
	local page = self.page
	if page.kind == "album" and self.library ~= nil then
		local album = self.library:album(page.id)
		return album and album.title or "Album"
	elseif page.kind == "artist" and self.library ~= nil then
		local artist = self.library:artist(page.id)
		return artist and artist.name or "Artist"
	elseif page.kind == "playlist" and self.taxonomy ~= nil then
		local playlist = self.taxonomy:playlist(page.id)
		return playlist and playlist.name or "Playlist"
	elseif page.kind == "settings" then
		return "Settings"
	elseif page.kind == "folders" then
		return "Folder"
	end

	return page.kind:sub(1, 1):upper() .. page.kind:sub(2)
end

---@return beat.Track?
function App:currentTrack()
	return self.player:current()
end

--- Playlists a sidebar shortcut can show, most recently played first. Plays are what order
--- them; a playlist never played but recently edited still beats an older one, and the name
--- breaks the remaining ties so the order does not wander between frames.
---@param limit number?
---@return beat.Playlist[]
function App:recentPlaylists(limit)
	local list = {}
	if self.taxonomy == nil then return list end
	for _, playlist in ipairs(self.taxonomy.playlists) do list[#list + 1] = playlist end
	local plays = self.taxonomy.metrics.playlists
	table.sort(list, function(a, b)
		local aMetric = plays[a.id]
		local bMetric = plays[b.id]
		local aLast = aMetric and aMetric.last or 0
		local bLast = bMetric and bMetric.last or 0
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

--- A ticker asleep for the idle interval still has a frame to show when something starts
--- moving: a page slide, a toast, a theme fade. Wake it now rather than waiting for the next
--- idle tick, which is later than the animation itself.
function App:wake()
	if self.ticker ~= nil then self.ticker.due = 0 end
end

---@param page any
---@param keepFocus boolean? # Whether a field already being typed in keeps the keyboard across the page change
function App:go(page, keepFocus)
	---@cast page beat.Page
	if samePage(page, self.page) then
		if page.kind ~= "folders" then
			-- A click on the page already showing does not navigate, but it must still not
			-- leave a transition from a moment ago frozen on its first frame.
			self:wake()
			return
		end
	end

	self.scrollMax = nil
	self.accentPickerOpen = false
	self.contextMenu = nil
	self.trackMenu = nil
	self.playlistMenu = nil
	self.tagPickerOpen = false
	self.tagDialogOpen = false
	self.playlistDialog = nil
	self.playlistPicker = nil
	self.tagPickerOpen = false
	self.tagEditId = nil
	self.tagDeleteId = nil
	self.hoverTagId = nil
	self.hoverPlaylist = nil
	self.playlistAdder = nil
	if not keepFocus then self:focusField(nil) end
	self.history[#self.history + 1] = self.page
	self.future = {}

	self.page = page
	self.transition = { start = time.now(), direction = 1}
	self.expanded = false
	self:wake()
	self:refresh()
end

function App:back()
	if #self.history == 0 then return end
	self.future[#self.future + 1] = self.page
	self.scrollMax = nil
	self.accentPickerOpen = false
	self.contextMenu = nil
	self.trackMenu = nil
	self.playlistMenu = nil
	self.tagPickerOpen = false
	self.tagDialogOpen = false
	self.playlistDialog = nil
	self.playlistPicker = nil
	self.tagPickerOpen = false
	self.tagEditId = nil
	self.tagDeleteId = nil
	self.hoverTagId = nil
	self.hoverPlaylist = nil
	self.playlistAdder = nil
	self:focusField(nil)
	self.page = table.remove(self.history) or self.page
	self.transition = { start = time.now(), direction = -1}
	self.expanded = false
	self:wake()
	self:refresh()
end

function App:forward()
	if #self.future == 0 then return end
	self.history[#self.history + 1] = self.page
	self.scrollMax = nil
	self.accentPickerOpen = false
	self.contextMenu = nil
	self.trackMenu = nil
	self.playlistMenu = nil
	self.tagPickerOpen = false
	self.tagDialogOpen = false
	self.playlistDialog = nil
	self.playlistPicker = nil
	self.tagPickerOpen = false
	self.tagEditId = nil
	self.tagDeleteId = nil
	self.hoverTagId = nil
	self.hoverPlaylist = nil
	self.playlistAdder = nil
	self:focusField(nil)
	self.page = table.remove(self.future) or self.page
	self.transition = { start = time.now(), direction = 1}
	self.expanded = false
	self:wake()
	self:refresh()
end

---@return string
function App:sortLabel()
	local labels = {
	title = "Title",
	artist = "Artist",
	year = "Year",
	recent = "Recently added",
	modified = "File modified",
	}
	return labels[self.settings.sort] or self.settings.sort
end

--- Tags selected on the search screen. Empty means no filtering.
---@return number[]
function App:tagFilterIds()
	local ids = {}
	for id, on in pairs(self.tagFilter) do
			if on then ids[#ids + 1] = id end
		end
	table.sort(ids)
	return ids
end

---@param query string
---@return beat.Album[] albums, beat.Artist[] artists, beat.Track[] tracks
function App:searchResults(query)
	if self.library == nil then return {}, {}, {} end
	local albums, artists, tracks = self.library:search(query)
	local ids = self:tagFilterIds()
	if #ids == 0 then return albums, artists, tracks end

	local matchedTracks = {}
	for _, track in ipairs(tracks) do
			if self.taxonomy:matches(track.path, ids, self.tagFilterMatch) then
				matchedTracks[#matchedTracks + 1] = track
			end
		end

	local matchedAlbums = {}
	for _, album in ipairs(albums) do
			local keep = false
			for _, track in ipairs(album.tracks) do
					if self.taxonomy:matches(track.path, ids, self.tagFilterMatch) then keep = true; break end
				end
			if keep then matchedAlbums[#matchedAlbums + 1] = album end
		end

	local matchedArtists = {}
	for _, artist in ipairs(artists) do
			local keep = false
			for _, track in ipairs(artist.tracks) do
					if self.taxonomy:matches(track.path, ids, self.tagFilterMatch) then keep = true; break end
				end
			if keep then matchedArtists[#matchedArtists + 1] = artist end
		end

	return matchedAlbums, matchedArtists, matchedTracks
end

---@return beat.Album[]
function App:albumList()
	local order = self.settings.sort
	if self.sortedAlbums ~= nil and self.sortedFor == order then return self.sortedAlbums end
	if self.library == nil then return {} end

	local albums = {}
	for _, album in ipairs(self.library.albums) do albums[#albums + 1] = album end

	if order == "artist" then
		table.sort(albums, function(a, b)
			local aa, ba = util.fold(a.artist), util.fold(b.artist)
			if aa ~= ba then return aa < ba end
			return util.fold(a.title) < util.fold(b.title)
		end)
	elseif order == "year" then
		table.sort(albums, function(a, b)
			local ay, by = a.year or 0, b.year or 0
			if ay ~= by then return ay > by end
			return util.fold(a.title) < util.fold(b.title)
		end)
	elseif order == "recent" then
		albums = {}
		for at = #self.library.recent, 1, -1 do albums[#albums + 1] = self.library.recent[at] end
	elseif order == "modified" then
		table.sort(albums, function(a, b)
			if a.modified ~= b.modified then return a.modified > b.modified end
			return util.fold(a.title) < util.fold(b.title)
		end)
	end

	self.sortedAlbums = albums
	self.sortedFor = order
	return albums
end

---@param count number
---@param perRow number
---@param rowHeight number
---@param offset number
---@param viewport number
---@return number first
---@return number last
---@return number top
function App:slices(count, perRow, rowHeight, offset, viewport)
	if count == 0 then return 1, 0, 0 end
	perRow = math.max(1, perRow)
	rowHeight = math.max(1, rowHeight)

	local rows = math.ceil(count / perRow)
	local visible = math.ceil(viewport / rowHeight) + 2
	local firstRow = math.min(rows, math.max(1, math.floor(offset / rowHeight) + 1))
	local lastRow = math.min(rows, firstRow + visible)
	local first = (firstRow - 1) * perRow + 1
	local last = math.min(count, lastRow * perRow)

	return first, last, (firstRow - 1) * rowHeight
end

---@param animate boolean? # False for a live picker, whose turns should not trail the pointer
function App:themeChanged(animate)
	local previous = self.theme
	self.theme = ui.theme.new(self.settings.theme, self.settings.accent, self.settings.uiScale)

	if animate ~= false and previous ~= nil and self.window ~= nil and not self.motion.reduce then
		self.theme.fromColors = previous.colors
		self.theme.mix = 0
		self.themeFade = { start = time.now()}
	else
		self.themeFade = nil
	end

	self:markSettingsDirty()
end

-- ────────────────────────────────────────────────────────────────
-- tags and playlists
-- ────────────────────────────────────────────────────────────────

---@param playlistId number
---@param shuffle boolean?
---@return boolean
function App:playPlaylist(playlistId, shuffle)
	local playlist = self.taxonomy:playlist(playlistId)
	if playlist == nil or self.library == nil then return false end
	local tracks = self.taxonomy:playlistTracks(playlist, self.library)
	if #tracks == 0 then
		self:toast("That playlist has no tracks yet", "error")
		return false
	end
	self.player:playTracks(tracks, 1, {
	source = "playlist:" .. tostring(playlist.id),
	shuffle = shuffle == true,
	})
	self:toast("Playing " .. playlist.name)
	return true
end

-- ────────────────────────────────────────────────────────────────
-- actions
-- ────────────────────────────────────────────────────────────────

--- The built-in shapes and the ones this person has saved, in the order the panel draws them.
---@return beat.EqualizerPreset[]
function App:equalizerPresets()
	local list = {}
	for _, preset in ipairs(core.equalizer.presets) do list[#list + 1] = preset end
	for _, preset in ipairs(self.settings.equalizerCustomPresets) do
			list[#list + 1] = {
			id = preset.name,
			name = preset.name,
			gains = preset.gains,
			custom = true,
			}
		end
	return list
end

---@param id string?
---@return beat.EqualizerPreset?
function App:findEqualizerPreset(id)
	if id == nil then return nil end
	for _, preset in ipairs(self:equalizerPresets()) do
			if preset.id == id then return preset end
		end
	return nil
end

---@return string
function App:nextEqualizerPresetName()
	local used = {}
	for _, preset in ipairs(self:equalizerPresets()) do used[preset.name] = true end
	local name = "Custom"
	local number = 2
	while used[name] do
		name = "Custom " .. tostring(number)
		number = number + 1
	end
	return name
end

---@param oldName string
---@param newName string
---@return boolean
function App:equalizerPresetNameFree(oldName, newName)
	for _, preset in ipairs(self:equalizerPresets()) do
			if preset.name == newName and preset.name ~= oldName then return false end
		end
	return true
end

---@param message any
function App:act(message)
	if type(message) ~= "table" or message.type == nil then return end
	local kind = message.type

	-- A tooltip belongs to the pointer being on its row. Any other message means it left, or
	-- something was pressed, and the frame built for the action must not keep the old label.
	if kind ~= "hoverPlaylist" and self.hoverPlaylist ~= nil then self.hoverPlaylist = nil end

	-- The volume bubble and the two now-playing panels belong to whatever opened them. Any other
	-- press closes them, so they cannot sit over the next screen -- except the press that opens or
	-- adjusts one of them.
	if kind ~= "toggleVolume" and kind ~= "volumeKeep" and kind ~= "volume" and kind ~= "mute" then
		self.volumeOpen = false
	end
	if kind ~= "toggleQueue" and kind ~= "queueKeep" and kind ~= "openQueue" then
		self.queueOpen = false
	end
	if kind ~= "toggleMore" and kind ~= "moreKeep" then
		self.moreOpen = false
	end
	if kind ~= "toggleEqualizer" and kind ~= "equalizerKeep" and kind ~= "equalizerGain"
	and kind ~= "equalizerPreset" and kind ~= "newEqualizerPreset"
	and kind ~= "editEqualizerPreset" and kind ~= "equalizerEditDraft"
	and kind ~= "saveEqualizerPresetRename" and kind ~= "deleteEqualizerPreset"
	and kind ~= "cancelEqualizerPresetRename" and kind ~= "equalizerEditKeep" then
		self.equalizerOpen = false
	end
	if kind ~= "editEqualizerPreset" and kind ~= "equalizerEditDraft"
	and kind ~= "saveEqualizerPresetRename" and kind ~= "deleteEqualizerPreset"
	and kind ~= "cancelEqualizerPresetRename" and kind ~= "equalizerEditKeep" then
		self.equalizerEdit = nil
	end

	if kind == "navigate" then
		self:go(message.page)
	elseif kind == "back" then
		self:back()
	elseif kind == "forward" then
		self:forward()
	elseif kind == "search" then
		self.search = message.value or ""
		if self.page.kind ~= "search" then
			---@type beat.Page
			local page = { kind = "search"}
			-- The search field started this navigation. It keeps the keyboard and its caret, so
			-- the next character is typed after the first rather than put in front of it.
			self:go(page, true)
		else
			self:refresh()
		end
	elseif kind == "clearSearch" then
		self.search = ""
		self:refresh()
	elseif kind == "playAlbum" then
		local album = self.library and self.library:album(message.id --[[@as number]])
		if album ~= nil then
			local current = self.player:current()
			if not message.shuffle and current ~= nil and current.albumId == album.id then
				self.player:toggle()
			elseif message.shuffle then
				self.player:playTracks(album.tracks, 1, { shuffle = true, source = "album"})
			else
				self.player:playAlbum(album)
			end
		end
	elseif kind == "playArtist" then
		local artist = self.library and self.library:artist(message.id --[[@as number]])
		if artist ~= nil then self.player:playArtist(artist, message.trackId) end
	elseif kind == "playTrack" then
		local track = self.library and self.library:track(message.trackId)
		local tracks = nil
		if message.albumId ~= nil and self.library ~= nil then
			local album = self.library:album(message.albumId --[[@as number]])
			tracks = album and album.tracks
		elseif message.artistId ~= nil and self.library ~= nil then
			local artist = self.library:artist(message.artistId --[[@as number]])
			tracks = artist and artist.tracks
		end
		local current = self.player:current()
		if track ~= nil and current ~= nil and current.id == track.id then
			self.player:toggle()
		elseif track ~= nil then
			self.player:playTrack(track, tracks)
		end
	elseif kind == "togglePlay" then
		if self.player.queue == nil then
			if self.page.kind == "album" and self.library ~= nil then
				local album = self.library:album(self.page.id)
				if album ~= nil then self.player:playAlbum(album) end
			elseif self.library ~= nil and #self.library.tracks > 0 then
				self.player:playTracks(self.library.tracks, 1, { source = "library"})
			end
		else
			self.player:toggle()
		end
	elseif kind == "jumpTrack" then
		self.player:jump(message.trackId)
	elseif kind == "next" then
		self.player:next()
	elseif kind == "previous" then
		self.player:previous()
	elseif kind == "seek" then
		self.player:seek(message.seconds or 0)
	elseif kind == "toggleVolume" then
		self.volumeOpen = not self.volumeOpen
		self.queueOpen = false
		self.moreOpen = false
		self:refresh()
	elseif kind == "volumeKeep" then
		-- The bubble itself is a click target, so a press on its padding does not close it.
	elseif kind == "toggleQueue" then
		self.queueOpen = not self.queueOpen
		self.volumeOpen = false
		self.moreOpen = false
		self:refresh()
	elseif kind == "openQueue" then
		self.queueOpen = true
		self.moreOpen = false
		self:refresh()
	elseif kind == "closeQueue" then
		self.queueOpen = false
		self:refresh()
	elseif kind == "queueKeep" then
		-- The queue panel is a click target, so a press on its padding does not close it.
	elseif kind == "toggleMore" then
		self.moreOpen = not self.moreOpen
		self.volumeOpen = false
		self.queueOpen = false
		self:refresh()
	elseif kind == "closeMore" then
		self.moreOpen = false
		self:refresh()
	elseif kind == "moreKeep" then
		-- The menu panel is a click target, so a press on its padding does not close it.
	elseif kind == "nowPlayingPlaylist" then
		local track = self:currentTrack()
		if track ~= nil then
			self.playlistPicker = { kind = "track", id = track.id}
			self:refresh()
		end
	elseif kind == "toggleEqualizer" then
		self.equalizerOpen = not self.equalizerOpen
		self.volumeOpen = false
		self.queueOpen = false
		self.moreOpen = false
		self:refresh()
	elseif kind == "closeEqualizer" then
		self.equalizerOpen = false
		self.equalizerEdit = nil
		self.equalizerEditDraft = ""
		self:focusField(nil)
		self:refresh()
	elseif kind == "equalizerKeep" then
		-- The panel itself is a click target, so a press on its padding does not close it.
	elseif kind == "equalizerEditKeep" then
		-- The rename dialog is a click target too.
	elseif kind == "equalizerPreset" then
		local preset = self:findEqualizerPreset(message.id)
		if preset ~= nil then
			self.settings.equalizerPreset = preset.id
			self.settings.equalizerGains = core.equalizer.copyGains(preset.gains)
			self.player:setEqualizer(core.equalizer.bands(self.settings.equalizerGains))
			self:markSettingsDirty()
			self:refresh()
		end
	elseif kind == "newEqualizerPreset" then
		if #self.settings.equalizerCustomPresets >= 8 then
			self:toast("That is enough custom presets for now", "error")
		else
			local name = self:nextEqualizerPresetName()
			local gains = core.equalizer.copyGains(self.settings.equalizerGains)
			self.settings.equalizerCustomPresets[#self.settings.equalizerCustomPresets + 1] = {
			name = name,
			gains = gains,
			}
			self.settings.equalizerPreset = name
			self.player:setEqualizer(core.equalizer.bands(gains))
			self:markSettingsDirty()
			self:refresh()
		end
	elseif kind == "editEqualizerPreset" then
		local preset = self:findEqualizerPreset(message.name)
		if preset ~= nil and preset.custom then
			self.equalizerEdit = preset.name
			self.equalizerEditDraft = preset.name
			self:focusField("equalizerPresetName", #preset.name)
			self:refresh()
		end
	elseif kind == "equalizerEditDraft" then
		self.equalizerEditDraft = message.value or ""
		self:refresh()
	elseif kind == "cancelEqualizerPresetRename" then
		self.equalizerEdit = nil
		self.equalizerEditDraft = ""
		self:focusField(nil)
		self:refresh()
	elseif kind == "saveEqualizerPresetRename" then
		local oldName = self.equalizerEdit
		local newName = self.equalizerEditDraft:match("^%s*(.-)%s*$")
		if oldName ~= nil and newName ~= "" then
			if not self:equalizerPresetNameFree(oldName, newName) then
				self:toast("Choose a preset name that is not already used", "error")
			else
				local found
				for _, preset in ipairs(self.settings.equalizerCustomPresets) do
						if preset.name == oldName then found = preset end
					end
				if found ~= nil then
					found.name = newName
					if self.settings.equalizerPreset == oldName then
						self.settings.equalizerPreset = newName
					end
					self.equalizerEdit = nil
					self.equalizerEditDraft = ""
					self:focusField(nil)
					self:markSettingsDirty()
					self:refresh()
				end
			end
		elseif oldName ~= nil then
			self:toast("Choose a preset name", "error")
		end
	elseif kind == "deleteEqualizerPreset" then
		local name = message.name or self.equalizerEdit
		local found
		for at, preset in ipairs(self.settings.equalizerCustomPresets) do
				if preset.name == name then found = at; break end
			end
		if found ~= nil then
			table.remove(self.settings.equalizerCustomPresets, found)
			if self.settings.equalizerPreset == name then
				self.settings.equalizerPreset = "flat"
				self.settings.equalizerGains = core.equalizer.presetGains("flat")
				self.player:setEqualizer(core.equalizer.bands(self.settings.equalizerGains))
			end
			self.equalizerEdit = nil
			self.equalizerEditDraft = ""
			self:focusField(nil)
			self:markSettingsDirty()
			self:refresh()
		end
	elseif kind == "equalizerGain" then
		local band = message.band
		if type(band) == "number" and band >= 1 and band <= #core.equalizer.frequencies then
			local gains = core.equalizer.sanitize(self.settings.equalizerGains)
			gains[band] = core.equalizer.clamp(message.value or 0)
			local selected = self:findEqualizerPreset(self.settings.equalizerPreset)
			if selected ~= nil and selected.custom then
				for _, preset in ipairs(self.settings.equalizerCustomPresets) do
						if preset.name == selected.id then preset.gains = core.equalizer.copyGains(gains) end
					end
			else
				self.settings.equalizerPreset = "custom"
			end
			self.settings.equalizerGains = gains
			self.player:setEqualizer(core.equalizer.bands(gains))
			self:markSettingsDirty()
			self:refresh()
		end
	elseif kind == "volume" then
		self.settings.volume = util.clamp(message.value or 0, 0, 1)
		self.settings.isMuted = false
		self.player.isMuted = false
		self.player:setVolume(self.settings.volume)
		self:markSettingsDirty()
	elseif kind == "mute" then
		self.settings.isMuted = self.player:toggleMute()
		self:markSettingsDirty()
	elseif kind == "shuffle" then
		local queue = self.player.queue
		if queue ~= nil then self.player:setShuffle(not queue.shuffle) end
	elseif kind == "repeat" then
		self.player:cycleRepeat()
	elseif kind == "expandNowPlaying" then
		self.expanded = message.open == true
		self.motion:animate("nowPlaying", self.expanded and 1 or 0, 0.28,
		self.expanded and ui.motion.ease.outBack or ui.motion.ease.inCubic)
	elseif kind == "chooseFolder" then
		if self.folderPick == nil and not self.folderAsk then
			-- Asked for on the next tick rather than here: the dialog runs a message loop of its own
			-- until it is answered, and one started from inside the click that asked for it is a loop
			-- inside this app's own -- every message it hands over arrives in the middle of the one
			-- being handled. A tick has no message being handled.
			self.folderAsk = true
		end
	elseif kind == "cancelFolders" then
		self:back()
	elseif kind == "folderOpen" then
		self:readFolder(message.path)
		self:refresh()
	elseif kind == "folderGo" then
		local typed = message.path or self.folderDraft
		if type(typed) == "string" and typed:match("%S") then
			self:readFolder(typed)
			self:refresh()
		end
	elseif kind == "folderDraft" then
		self.folderDraft = message.value or ""
		self:refresh()
	elseif kind == "folderUp" then
		local folder = self.folderPath
		if folder ~= nil then
			local parent = folders.parent(folder)
			-- Above a Windows drive are the drives; "/" has nothing above it.
			if parent ~= nil or folders.windows then
				self:readFolder(parent)
				self:refresh()
			end
		end
	elseif kind == "folderSelect" then
		local chosen = message.path or self.folderPath
		if chosen ~= nil then self:startScan(chosen) end
	elseif kind == "rescan" then
		local root = self.settings.root
		if root ~= nil then self:startScan(root) end
	elseif kind == "cancelScan" then
		if self.scan ~= nil then
			self.scan:cancel()
			self.scan = nil
			self.scanIslandOpen = false
			self:toast("Scan cancelled")
			self:refresh()
		end
	elseif kind == "hideScanIsland" then
		self.scanIslandOpen = false
		self:refresh()
	elseif kind == "showScanIsland" then
		self.scanIslandOpen = true
		self:refresh()
	elseif kind == "theme" then
		self.settings.theme = message.name
		self:themeChanged()
	elseif kind == "accent" then
		self.settings.accent = message.name
		self:themeChanged()
	elseif kind == "openAccentPicker" then
		self.accentPickerOpen = true
		self.accentDraft = self.settings.accent:match("#")
		and self.settings.accent or ui.theme.accentColour(self.settings.accent)
		self:refresh()
	elseif kind == "pickAccent" then
		local value = message.value
		if type(value) == "string" and value:match("^#%x%x%x%x%x%x$") then
			self.accentDraft = value:lower()
			self:refresh()
		end
	elseif kind == "confirmAccent" then
		if self.accentDraft ~= nil and self.accentDraft:match("^#%x%x%x%x%x%x$") then
			self.settings.accent = self.accentDraft
			self:themeChanged(false)
		end
		self.accentPickerOpen = false
		self.accentDraft = nil
		self:refresh()
	elseif kind == "closeAccentPicker" then
		self.accentPickerOpen = false
		self.accentDraft = nil
		self:refresh()
	elseif kind == "albumMenu" then
		if self.library ~= nil and self.library:album(message.id --[[@as number]]) ~= nil then
			self.contextMenu = { id = message.id, x = message.x or 0, y = message.y or 0}
			self:refresh()
		end
	elseif kind == "closeAlbumMenu" then
		self.contextMenu = nil
		self:refresh()
	elseif kind == "albumMenuPlay" or kind == "albumMenuNext" or kind == "albumMenuQueue" then
		local album = self.library and self.library:album(message.id --[[@as number]])
		self.contextMenu = nil
		if album ~= nil then
			if kind == "albumMenuPlay" then
				self.player:playAlbum(album)
			elseif kind == "albumMenuNext" then
				self.player:playNext(album.tracks)
				self:toast("Playing next · " .. album.title)
			else
				self.player:addToQueue(album.tracks)
				self:toast("Added to queue · " .. album.title)
			end
		end
		self:refresh()
	elseif kind == "openTagPicker" then
		local track = self.library and self.library:track(message.id --[[@as number]])
		if track ~= nil then
			self.tagTrackId = track.id
			self.tagPickerOpen = true
			self.tagEditId = nil
			self:refresh()
		end
	elseif kind == "closeTagPicker" then
		self.tagPickerOpen = false
		self:refresh()
	elseif kind == "tagPickerKeep" then
		-- The panel itself is a click target, so a click on its padding does not close it.
	elseif kind == "toggleTrackTag" then
		local track = self.tagTrackId ~= nil and self.library ~= nil
		and self.library:track(self.tagTrackId) or self:currentTrack()
		if track ~= nil then
			self.taxonomy:toggleTag(track.path, message.id)
			self:saveTaxonomy()
			self:refresh()
		end
	elseif kind == "openTagDialog" then
		self.tagPickerOpen = false
		self.playlistDialog = nil
		self.playlistPicker = nil
		self.tagDialogOpen = true
		self.tagDraft = ""
		self:focusField("newTag")
		self:refresh()
	elseif kind == "tagDraft" then
		self.tagDraft = message.value or ""
		self:refresh()
	elseif kind == "closeTagDialog" then
		self.tagDialogOpen = false
		self.tagDraft = ""
		self:focusField(nil)
		self:refresh()
	elseif kind == "tagDialogKeep" then
		-- The panel itself is a click target, so a click on its padding does not close it.
	elseif kind == "createTag" then
		local tag = self.taxonomy:addTag(self.tagDraft)
		if tag == nil then
			self:toast("Choose a tag name that is not already used", "error")
		else
			self:saveTaxonomy()
			self.tagDialogOpen = false
			self.tagDraft = ""
			self:focusField(nil)
			self:toast("Tag created · " .. tag.name)
		end
		self:refresh()
	elseif kind == "openPlaylistDialog" then
		self.tagPickerOpen = false
		self.tagDialogOpen = false
		self.playlistPicker = nil
		self.playlistDialog = {
		smart = message.smart == true,
		name = "",
		tagIds = {},
		match = "all",
		}
		self:focusField("playlistName")
		self:refresh()
	elseif kind == "closePlaylistDialog" then
		self.playlistDialog = nil
		self:focusField(nil)
		self:refresh()
	elseif kind == "tagDeleteKeep" then
		-- The panel itself is a click target.
	elseif kind == "playlistDialogKeep" then
		-- The panel itself is a click target, so a click on its padding does not close it.
	elseif kind == "playlistDraft" then
		if self.playlistDialog ~= nil then
			self.playlistDialog.name = message.value or ""
			self:refresh()
		end
	elseif kind == "playlistDraftTag" then
		local dialog = self.playlistDialog
		if dialog ~= nil and message.id ~= nil then
			if dialog.tagIds[message.id] then dialog.tagIds[message.id] = nil
			else dialog.tagIds[message.id] = true end
			self:refresh()
		end
	elseif kind == "playlistDraftMatch" then
		if self.playlistDialog ~= nil then
			self.playlistDialog.match = message.value == "any" and "any" or "all"
			self:refresh()
		end
	elseif kind == "createPlaylist" then
		local dialog = self.playlistDialog
		if dialog ~= nil then
			local tagIds = {}
			for id in pairs(dialog.tagIds) do tagIds[#tagIds + 1] = id end
			table.sort(tagIds)
			local playlist = self.taxonomy:addPlaylist(dialog.name, #tagIds > 0, tagIds,
			dialog.match, { manual = true})
			if playlist == nil then
				self:toast("Choose a playlist name", "error")
			else
				self:saveTaxonomy()
				self.playlistDialog = nil
				self:focusField(nil)
				self:toast("Playlist created · " .. playlist.name)
			end
		end
		self:refresh()
	elseif kind == "playPlaylist" then
		self:playPlaylist(message.id --[[@as number]], message.shuffle == true)
		self:refresh()
	elseif kind == "playlistMenu" then
		if self.taxonomy:playlist(message.id --[[@as number]]) ~= nil then
			self.contextMenu = nil
			self.trackMenu = nil
			self.playlistMenu = { id = message.id, x = message.x or 0, y = message.y or 0}
			self:refresh()
		end
	elseif kind == "playlistMenuKeep" then
		-- The panel itself is a click target.
	elseif kind == "closePlaylistMenu" then
		self.playlistMenu = nil
		self:refresh()
	elseif kind == "deletePlaylist" then
		self:deletePlaylist(message.id --[[@as number]])
		self:refresh()
	elseif kind == "playlistPicker" then
		self.contextMenu = nil
		self.trackMenu = nil
		self.playlistPicker = { kind = message.kind, id = message.id}
		self:refresh()
	elseif kind == "closePlaylistPicker" then
		self.playlistPicker = nil
		self:refresh()
	elseif kind == "playlistPickerKeep" then
		-- The panel itself is a click target, so a click on its padding does not close it.
	elseif kind == "addToPlaylist" then
		local playlist = self.taxonomy:playlist(message.playlistId)
		local picker = self.playlistPicker
		if playlist ~= nil and picker ~= nil and self.library ~= nil then
			if picker.kind == "album" then
				local album = self.library:album(picker.id)
				if album ~= nil then self.taxonomy:setPlaylistAlbum(playlist, album) end
			else
				local track = self.library:track(picker.id)
				if track ~= nil then self.taxonomy:setPlaylistTrack(playlist, track.path, true) end
			end
			self:saveTaxonomy()
			self:toast("Added to " .. playlist.name)
		end
		self.playlistPicker = nil
		self:refresh()
	elseif kind == "trackMenu" then
		self.trackMenu = { id = message.id, x = message.x or 0, y = message.y or 0}
		self:refresh()
	elseif kind == "closeTrackMenu" then
		self.trackMenu = nil
		self:refresh()
	elseif kind == "trackMenuKeep" then
		-- The panel itself is a click target, so a click on its padding does not close it.
	elseif kind == "trackMenuPlay" then
		local track = self.library and self.library:track(message.id --[[@as number]])
		self.trackMenu = nil
		if track ~= nil then self.player:playTrack(track) end
		self:refresh()
	elseif kind == "trackMenuPlaylist" then
		self.trackMenu = nil
		self.playlistPicker = { kind = "track", id = message.id}
		self:refresh()
	elseif kind == "toggleTagFilter" then
		if self.tagFilter[message.id] then self.tagFilter[message.id] = nil
		else self.tagFilter[message.id] = true end
		self:refresh()
	elseif kind == "tagFilterMatch" then
		self.tagFilterMatch = message.value == "any" and "any" or "all"
		self:refresh()
	elseif kind == "clearTagFilter" then
		self.tagFilter = {}
		self:refresh()
	elseif kind == "hoverPlaylist" then
		local id = tonumber(message.id)
		local playlist = id ~= nil and self.taxonomy ~= nil and self.taxonomy:playlist(id) or nil
		if playlist == nil then
			self.hoverPlaylist = nil
		else
			local y = tonumber(message.y) or 0
			local top = tonumber(message.top)
			local x = tonumber(message.x)
			local height = tonumber(message.height)
			local old = self.hoverPlaylist
			if old == nil or old.id ~= id or old.y ~= y or old.top ~= top
			or old.x ~= x or old.height ~= height then
				self.hoverPlaylist = {
				id = id --[[@as number]], y = y, top = top, x = x, height = height,
				}
			end
		end
	elseif kind == "hoverTag" then
		if self.hoverTagId ~= message.id then
			self.hoverTagId = message.id
			self:refresh()
		end
	elseif kind == "editTag" then
		local tag = self.taxonomy.tagById[tonumber(message.id)]
		if tag ~= nil and not tag.hidden then
			self.tagEditId = tag.id
			self.tagEditDraft = tag.name
			self.tagDialogOpen = false
			self:focusField("tagName", #tag.name)
			self:refresh()
		end
	elseif kind == "tagEditDraft" then
		self.tagEditDraft = message.value or ""
		self:refresh()
	elseif kind == "cancelTagEdit" then
		self.tagEditId = nil
		self.tagEditDraft = ""
		self:focusField(nil)
		self:refresh()
	elseif kind == "renameTag" then
		local tag = self.taxonomy:renameTag(self.tagEditId --[[@as number]], self.tagEditDraft)
		if tag == nil then
			self:toast("Choose a tag name that is not already used", "error")
		else
			self:saveTaxonomy()
			self.tagEditId = nil
			self.tagEditDraft = ""
			self:focusField(nil)
			self:toast("Tag renamed · " .. tag.name)
		end
		self:refresh()
	elseif kind == "deleteTag" then
		local id = tonumber(message.id)
		local tag = id ~= nil and self.taxonomy.tagById[id] or nil
		if tag ~= nil then
			if tag.count > 0 then
				self.tagDeleteId = tag.id
				self.tagDialogOpen = false
				self:refresh()
			else
				self:deleteTag(tag.id)
				self:refresh()
			end
		end
	elseif kind == "cancelDeleteTag" then
		self.tagDeleteId = nil
		self:refresh()
	elseif kind == "confirmDeleteTag" then
		if self.tagDeleteId ~= nil then self:deleteTag(self.tagDeleteId) end
		self.tagDeleteId = nil
		self:refresh()
	elseif kind == "openPlaylistAdder" then
		self.playlistAdder = { playlistId = message.id, query = ""}
		self:focusField("playlistAddSearch")
		self:refresh()
	elseif kind == "closePlaylistAdder" then
		self.playlistAdder = nil
		self:focusField(nil)
		self:refresh()
	elseif kind == "playlistAdderKeep" then
		-- The panel itself is a click target.
	elseif kind == "playlistAdderQuery" then
		if self.playlistAdder ~= nil then
			self.playlistAdder.query = message.value or ""
			self:refresh()
		end
	elseif kind == "playlistAddAlbum" then
		if self.playlistAdder ~= nil and self.library ~= nil then
			local playlist = self.taxonomy:playlist(self.playlistAdder.playlistId)
			local album = self.library:album(message.id --[[@as number]])
			if playlist ~= nil and album ~= nil then
				self.taxonomy:setPlaylistAlbum(playlist, album)
				self:saveTaxonomy()
				self:toast("Added " .. album.title .. " to " .. playlist.name)
			end
		end
		self:refresh()
	elseif kind == "playPlaylistTrack" then
		local playlist = self.taxonomy:playlist(message.playlistId --[[@as number]])
		if playlist ~= nil and self.library ~= nil then
			local tracks = self.taxonomy:playlistTracks(playlist, self.library)
			local index = 1
			for at, track in ipairs(tracks) do
					if track.id == message.trackId then index = at; break end
				end
			if #tracks > 0 then
				self.player:playTracks(tracks, index, { source = "playlist:" .. tostring(playlist.id)})
			end
		end
		self:refresh()
	elseif kind == "accentPickerKeep" then
		-- The panel itself is a click target, so a click on its padding does not close it.
	elseif kind == "uiScale" then
		self.settings.uiScale = message.value
		self:themeChanged()
	elseif kind == "sidebarWidth" then
		self.settings.sidebarWidth = util.clamp(message.width or 264, 200, 360)
		self:markSettingsDirty()
		self:refresh()
	elseif kind == "toggleSidebar" then
		self.settings.sidebarCollapsed = not self.settings.sidebarCollapsed
		self:markSettingsDirty()
		self:refresh()
	elseif kind == "reduceMotion" then
		self.settings.reduceMotion = message.value == true
		self.motion.reduce = self.settings.reduceMotion
		self:markSettingsDirty()
	elseif kind == "sortMenu" then
		self.sortOpen = message.value == nil and not self.sortOpen or message.value == true
	elseif kind == "sort" then
		self.settings.sort = message.value or "title"
		self.sortOpen = false
		self.sortedAlbums = nil
		self:markSettingsDirty()
	elseif kind == "toggleView" then
		self.settings.view = self.settings.view == "list" and "grid" or "list"
		self:markSettingsDirty()
	elseif kind == "lastfmConnect" then
		self.lastfm:connect()
		self:refresh()
	elseif kind == "lastfmCancel" then
		self.lastfm:cancelAuth()
		self:refresh()
	elseif kind == "lastfmOpenAuth" then
		if not self.lastfm:openAuthPage() then
			self:toast("Could not open a browser for Last.fm", "error")
		end
	elseif kind == "openURL" then
		local ok, opened = pcall(links.open, message.url)
		if not ok or not opened then
			self:toast("Could not open the link", "error")
		end
	elseif kind == "lastfmDisconnect" then
		self.lastfm:disconnect()
		self:refresh()
	elseif kind == "lastfmEnabled" then
		self.settings.lastfmEnabled = message.value == true
		self:markSettingsDirty()
		self:refresh()
	elseif kind == "scroll" then
		local key = self:pageKey()
		local offset = self.scroll[key] or 0
		local limit = self.scrollMax
		---@param value number
		local function clampScroll(value)
			value = math.max(0, value)
			return limit ~= nil and math.min(value, limit) or value
		end
		if message.to ~= nil then
			-- A bar dragged is already where the pointer put it: chasing it would make the
			-- thumb lag the hand moving it.
			offset = clampScroll(message.to --[[@as number]])
			self.scroll[key] = offset
			self.scrollTargets[key] = offset
			self.scrollAnimating = false
			self:refresh()
		else
			self.scroll[key] = offset
			self.scrollTargets[key] = clampScroll(
			(self.scrollTargets[key] or offset) + (message.by --[[@as number?]] or 0) * self.theme:px(60))
			self.scrollAnimating = true
			-- Start the easing clock now, then wake the ticker for the next frame instead of
			-- drawing once per wheel event.
			self.lastTick = time.now()
			if self.ticker ~= nil then self.ticker.due = 0 end
		end
	elseif kind == "toast" then
		self:toast(message.text or "", message.tone)
	elseif kind == "dismissToast" then
		for at = #self.toasts, 1, -1 do
				if self.toasts[at].at == message.at then table.remove(self.toasts, at) end
			end
	elseif kind == "dismissScanSummary" then
		self.scanSummary = nil
		self:refresh()
	end

	-- Whatever the action changed -- a page, a queue, a theme -- is worth a frame now rather
	-- than one at the idle interval, which is longer than the animations it starts.
	self:wake()
end

---@param message any
---@param _window winit.Window
function App:update(message, _window)
	self:act(message)
end

---@param event winit.Event
---@param handler winit.EventManager
function App:event(event, _handler)
	if event.name == "fileDrop" then
		local paths = event.paths or {}
		for _, drop in ipairs(paths) do
				if fs.isdir(drop) then
					self:startScan(drop)
					return nil
				end
			end
		self:toast("Drop a folder to build a library", "error")
		return nil
	end

	if event.name == "mousePress" then
		-- A press on the search field changes layout focus without producing a message. The
		-- focus ring is drawn from that state, so ask for the frame that shows it.
		self:refresh()
		return nil
	end

	if event.name ~= "keyPress" then return nil end
	local key = event.key
	local modifiers = event.modifiers or {}

	if key == "space" then
		self:act({ type = "togglePlay"})
	elseif key == "left" then
		self.player:seek(math.max(0, self.player:position() - 5))
	elseif key == "right" then
		self.player:seek(self.player:position() + 5)
	elseif key == "escape" then
		if self.expanded then
			self:act({ type = "expandNowPlaying", open = false})
		elseif self.page.kind == "search" and self.search ~= "" then
			self.search = ""
		elseif self.page.kind ~= "home" then
			self:back()
		end
	elseif key == "/" or (modifiers.ctrl and key == "f") then
		---@type beat.Page
		local searchPage = { kind = "search"}
		self:go(searchPage)
		self:focusField("search", #self.search)
	elseif modifiers.ctrl and key == "o" then
		self:act({ type = "chooseFolder"})
	elseif modifiers.ctrl and key == "," then
		---@type beat.Page
		local settingsPage = { kind = "settings"}
		self:go(settingsPage)
	end

	self:refresh()
	return nil
end

-- ────────────────────────────────────────────────────────────────
-- the ticker
-- ────────────────────────────────────────────────────────────────

---@param now number
---@param window wonderland.RenderWindow
---@return number
function App:tick(now, window)
	self.window = window
	local changed = false

	local dt = math.max(0, math.min(0.1, now - self.lastTick))
	self.lastTick = now
	if self.scrollAnimating then
		local moving = false
		for key, target in pairs(self.scrollTargets) do
				local offset = self.scroll[key] or 0
				local delta = target - offset
				if math.abs(delta) > 0.25 then
					self.scroll[key] = offset + delta * math.min(1, 18 * dt)
					moving = true
				else
					self.scroll[key] = target
				end
			end
		self.scrollAnimating = moving
		changed = true
	end

	if self.folderAsk then
		self.folderAsk = nil
		self.folderPick = Picker.start(self.window)
	end

	if self.folderPick ~= nil then
		local chosen, status = Picker.poll(self.folderPick)

		if chosen ~= nil then
			self.folderPick = nil
			self:startScan(chosen)
			changed = true
		elseif status ~= nil then
			self.folderPick = nil
			-- Where the platform has no dialog of its own, the app's browser is the one there is.
			if status == "no-picker" then self:browseFolders() end
			changed = true
		end
	end

	if self.scan ~= nil then
		local events, progressed = self.scan:poll(32)
		if progressed then changed = true end
		for _, event in ipairs(events) do
				---@cast event table
				if event.type == "track" and self.library ~= nil then
					local track, gainedCover
					local ok, err = pcall(function()
						track, gainedCover = self.library:add(event.info, event.entry, event.cover,
						event.coverCache)
					end)
					if not ok then
						self:toast("Could not read a scanned track", "error")
						self.scanErrors[#self.scanErrors + 1] = { path = event.entry.path, message = tostring(err)}
					elseif track ~= nil and (track.hasPicture or gainedCover) then
						self.covers:forget(track.albumId)
					end
					self.sortedAlbums = nil
					changed = true
				end
			end

		if self.scan ~= nil and self.scan:isDone() and not self.scan:hasPending() then
			local progress = self.scan:progress()
			if progress.phase == "done" then
				---@cast self.library -nil
				self.library:finish()
				LibraryCache.save(assert(self.library))
				self.sortedAlbums = nil
				self.scanSkipped = progress.skipped
				self.scanErrors = progress.errors
				self.scanSummary = {
				tracks = #self.library.tracks,
				albums = #self.library.albums,
				skipped = progress.skipped,
				at = now,
				}
			elseif self.scan.error ~= nil then
				self:toast(self.scan.error or "Scan failed", "error")
			else
				self:toast("Scan cancelled", "error")
			end
			self.scan:close()
			self.scan = nil
			self.scanIslandOpen = false
			changed = true
		end
	end

	if self.player:update(now) then changed = true end
	local current = self.player:current()
	local playing = self.player:isPlaying()
	if playing and current ~= nil and self.library ~= nil
	and current.id ~= self.lastListenedTrackId then
		self.lastListenedTrackId = current.id
		local playlistId = nil
		local source = self.player.queue and self.player.queue.source
		if source ~= nil then
			local id = source:match("^playlist:(%d+)$")
			if id ~= nil then playlistId = tonumber(id) end
		end
		self.taxonomy:recordListen(current, self.library, playlistId, os.time())
		self:saveTaxonomy()
		changed = true
	end
	self.scrobbler:update(current, self.player:position(), playing, os.time())
	if self.lastfm:update(current, playing, self.scrobbler:take()) then changed = true end
	if self.spectrum:step(now) then changed = true end
	local err = self.player:takeError()
	if err ~= nil then
		---@cast err string
		self:toast(err, "error")
		changed = true
	end

	if self.assets ~= nil and self.covers:step() then changed = true end
	if self.motion:update(now) then changed = true end

	if self.themeFade ~= nil then
		local progress = ui.motion.progress(self.themeFade.start, 0.22, now, ui.motion.ease.inOutCubic)
		-- Quantised so the crossfade reuses styles rather than interning a colour a frame.
		self.theme.mix = math.floor(progress * 32 + 0.5) / 32
		if progress >= 1 then
			self.theme.fromColors = nil
			self.themeFade = nil
		end
		changed = true
	end

	if self.transition ~= nil then
		-- The view reads the transition's progress every frame, so every frame of it is a frame
		-- the screen has to be handed: without this the slide only appeared at its start and end.
		if now >= self.transition.start + 0.28 then self.transition = nil end
		changed = true
	end

	if self.scanSummary ~= nil and now - self.scanSummary.at >= 5 then
		self.scanSummary = nil
		changed = true
	end

	-- A toast under the pointer stays there. Its box is recorded by the view that drew it, so the
	-- expiry clock can be moved before the next frame removes it; moving the pointer off starts the
	-- full life again rather than resuming a stale countdown.
	local pointer
	if self.window ~= nil and self.layoutPlugin ~= nil then
		if self.layoutPlugin.pointer ~= nil then
			pointer = self.layoutPlugin:pointer(self.window)
		else
			-- Older wonderland releases keep the pointer on the layout context itself.
			local contexts = self.layoutPlugin.contexts
			local context = contexts and contexts[self.window]
			pointer = context and context.pointer or nil
		end
	end

	local kept = {}
	for _, toast in ipairs(self.toasts) do
			local life = toast.tone == "error" and 8 or 4.5
			local expires = toast.expires or (toast.at + life)
			local box = toast.rect

			if pointer ~= nil and box ~= nil and pointer.x >= box.x and pointer.x <= box.x + box.width
			and pointer.y >= box.y and pointer.y <= box.y + box.height then
				expires = now + life
			end

			toast.expires = expires

			if now < expires then
				kept[#kept + 1] = toast
				if now - toast.at < 0.18 or expires - now < 0.3 then changed = true end
			else
				changed = true
			end
		end
	self.toasts = kept

	if self.dirtyAt ~= nil and now >= self.dirtyAt then
		self:saveSettings()
	end

	if changed then self:present(window) end

	local busy = self.scan ~= nil or self.folderPick ~= nil or self.player:isPlaying()
	or self.scrollAnimating or self.motion:isActive() or self.covers:hasPending() or self.transition ~= nil
	or self.themeFade ~= nil or #self.toasts > 0 or self.lastfm:isBusy()
	return busy and (1 / 60) or 0.5
end

---@param window wonderland.RenderWindow
---@param assets wonderland.Assets
---@return wonderland.Element
function App:view(window, assets)
	self.window = window
	self:setIcon(window)
	self.assets = assets
	self.covers:use(assets)
	return pages.view(self, window)
end

return App
