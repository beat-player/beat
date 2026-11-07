local ffi = require("ffi")
local wonderland = require("wonderland")
local core = require("beat-core")
local ui = require("beat-ui")
local fs = require("fs")

local Covers = require("beat.app.covers")
local shell = require("beat.app.shell")
local Picker = require("beat.app.picker")
local ScanJob = require("beat.app.scan_job")
local LibraryCache = require("beat.app.library_cache")
local Log = require("beat.app.log")
local LastfmClient = require("beat.app.lastfm")
local TagStore = require("beat.app.tag_store")
local surfaces = require("beat.app.surfaces")
local actions = require("beat.app.actions")

-- Written by build.lua from assets/icon-256.png, so a compiled binary carries it too.
local iconData = require("beat.app.icon")

local time = wonderland.time
local util = core.util

--- Where a navigation goes: a page kind and what picks the one page of that kind. `App:go` turns
--- it into a `beat.PageInstance`, which is what `App.page` and the history hold.
---@alias beat.Route
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
---@field page beat.PageInstance
---@field history beat.PageInstance[]
---@field future beat.PageInstance[]
---@field overlays beat.OverlayInstance[] # Open over the page, the last one on top
---@field search string
---@field scroll table<string, number>
---@field scrollTargets table<string, number>
---@field scrollAnimating boolean
---@field scrollMax number? # The furthest the page built last frame can scroll, where it knows
---@field lastTick number
---@field ticker table?
---@field scanSkipped number
---@field scanErrors { path: string, message: string }[]
---@field folderPick beat.FolderPick?
---@field scanIslandOpen boolean
---@field scanSummary { tracks: number, albums: number, skipped: number, at: number }?
---@field transition { start: number, direction: number? }?
---@field toasts { text: string, tone: string, at: number, expires: number, rect: { x: number, y: number, width: number, height: number }? }[]
---@field themeFade { start: number }?
---@field sortedAlbums beat.Album[]?
---@field sortedFor string?
---@field iconSet boolean
---@field taxonomy beat.Taxonomy
---@field tagFilter table<number, boolean>
---@field tagFilterMatch "all"|"any"
---@field hoverPlaylist { id: number, y: number, top: number?, x: number?, height: number? }?
---@field lastListenedTrackId number?
---@field dirtyAt number?
local App = wonderland.app("Beat")

--- Which page a route or a page is: two with the same key are the same page, and share where
--- they were scrolled to.
---@param page beat.Route|beat.PageInstance
---@return string
function App:keyOf(page)
	local surface = surfaces.page(page.kind)
	return surface.key ~= nil and surface.key(page --[[@as beat.PageInstance]]) or page.kind
end

--- A page for a route, with the state its module starts it with.
---@param route beat.Route
---@return beat.PageInstance
function App:pageFor(route)
	---@type beat.PageInstance
	local page = { kind = route.kind, state = {}}
	for field, value in pairs(route) do page[field] = value end
	local surface = surfaces.page(page.kind)
	page.state = surface.new ~= nil and surface.new(self, page) or {}
	return page
end

--- The page showing, with its state. A page put in place without one -- a test sets `App.page`
--- to a bare route -- is given the state its module starts with.
---@return beat.PageInstance
function App:currentPage()
	local page = self.page
	if page.state == nil then
		local surface = surfaces.page(page.kind)
		page.state = surface.new ~= nil and surface.new(self, page) or {}
	end
	return page
end

--- Opens an overlay on top of the others. Its module may refuse -- the album it is for is gone
--- -- and then nothing opens.
---@param name string
---@param params table?
---@return beat.OverlayInstance?
function App:open(name, params)
	local state = surfaces.overlay(name).new(self, params or {})
	if state == nil then return nil end
	---@type beat.OverlayInstance
	local overlay = { name = name, state = state}
	self.overlays[#self.overlays + 1] = overlay
	self:refresh()
	return overlay
end

--- Closes an overlay, or the topmost overlay with a name, and what was opened over it.
---@param which beat.OverlayInstance|string
function App:close(which)
	for at = #self.overlays, 1, -1 do
			local overlay = self.overlays[at]
			if overlay == which or overlay.name == which then
				for above = #self.overlays, at, -1 do
						local closing = table.remove(self.overlays, above)
						local surface = surfaces.overlay(closing.name)
						if surface.close ~= nil then surface.close(self, closing) end
					end
				self:refresh()
				return
			end
		end
end

function App:closeOverlays()
	if #self.overlays > 0 then self:close(self.overlays[1]) end
end

--- The topmost open overlay with a name.
---@param name string
---@return beat.OverlayInstance?
function App:overlay(name)
	for at = #self.overlays, 1, -1 do
			if self.overlays[at].name == name then return self.overlays[at] end
		end
	return nil
end

--- What a page change or a new library takes away: every overlay, and what the old screens keep
--- outside of one.
function App:closeTransient()
	self:closeOverlays()
	self.hoverPlaylist = nil
	-- The playlists page edits a tag's name in place; leaving it puts the pill back.
	local page = self.page
	if page ~= nil and page.kind == "playlists" then
		page = self:currentPage()
		page.state.tagEditId = nil
		page.state.hoverTagId = nil
	end
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
	self.tagFilter = {}
	self.tagFilterMatch = "all"
	self.hoverPlaylist = nil
	self.lastListenedTrackId = nil
	self.folderPick = nil
	self.scan = nil
	self.library = nil
	self.sortedAlbums = nil
	self.sortedFor = nil
	self.scanIslandOpen = true
	self.scanSummary = nil

	self.history = {}
	self.future = {}
	self.overlays = {}
	self.search = ""
	self.scroll = {}
	self.scrollTargets = {}
	self.scrollAnimating = false
	self.scrollMax = nil
	self.lastTick = time.now()
	self.toasts = {}
	self.lastfm = LastfmClient.new(self.settings, {
	onToast = function(text, tone) self:toast(text, tone) end,
	onSave = function() self:saveSettings() end,
	})

	self.motion:set("nowPlaying", 0)
	self.scanSkipped = 0
	self.scanErrors = {}

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
	-- After the library, so a page that reads it on opening sees it.
	self.page = self:pageFor({ kind = self.settings.root == nil and "folders" or "home"})

	self.ticker = self:onTick(function(now, window) return self:tick(now, window) end)
end

---@return boolean
function App:needsFolder()
	return self.settings.root == nil
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
	local page = self.page
	if page ~= nil and page.kind == "playlists" then
		page = self:currentPage()
		if page.state.tagEditId == tagId then
			page.state.tagEditId = nil
			page.state.tagEditDraft = ""
			self:focusField(nil)
		end
		if page.state.hoverTagId == tagId then page.state.hoverTagId = nil end
	end
	if self:overlay("tag_delete") ~= nil then self:close("tag_delete") end
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
		self.page = self:pageFor({ kind = "playlists"})
		self.scroll.playlists = 0
	end
	local adder = self:overlay("playlist_adder")
	if adder ~= nil and adder.state.playlistId == playlistId then self:close(adder) end
	self:close("playlist_picker")
	if self:overlay("tag_delete") ~= nil then self:close("tag_delete") end
	if self.hoverPlaylist ~= nil and self.hoverPlaylist.id == playlistId then self.hoverPlaylist = nil end
	self:close("playlist_menu")
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

---@param root string
function App:startScan(root)
	Picker.cancel(self.folderPick)
	self.folderPick = nil
	if self.scan ~= nil then self.scan:cancel() end
	self.player:close()
	self.spectrum:clear()
	self.covers:releaseAll()
	self.library = core.Library.new(root)
	self.sortedAlbums = nil
	self.scan = ScanJob.start(root)
	self.scanIslandOpen = true
	self.scanSummary = nil
	self:closeTransient()
	self:focusField(nil)
	self.settings.root = root
	self.page = self:pageFor({ kind = "home"})
	self.history = {}
	self.future = {}
	self.search = ""
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
	return self:keyOf(self.page)
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

---@param route beat.Route
---@param keepFocus boolean? # Whether a field already being typed in keeps the keyboard across the page change
function App:go(route, keepFocus)
	if self:keyOf(route) == self:pageKey() then
		-- A click on the page already showing does not navigate, but it must still not leave a
		-- transition from a moment ago frozen on its first frame.
		self:wake()
		return
	end

	self.scrollMax = nil
	self:closeTransient()
	if not keepFocus then self:focusField(nil) end
	self.history[#self.history + 1] = self.page
	self.future = {}

	self.page = self:pageFor(route)
	self.transition = { start = time.now(), direction = 1}
	self:wake()
	self:refresh()
end

--- Back and forward bring a page back as it was left: its state comes with it.
---@param from beat.PageInstance[]
---@param to beat.PageInstance[]
---@param direction number
function App:travel(from, to, direction)
	if #from == 0 then return end
	to[#to + 1] = self.page
	self.scrollMax = nil
	self:closeTransient()
	self:focusField(nil)
	self.page = table.remove(from)
	self.transition = { start = time.now(), direction = direction}
	self:wake()
	self:refresh()
end

function App:back()
	self:travel(self.history, self.future, -1)
end

function App:forward()
	self:travel(self.future, self.history, 1)
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

---@param message any
function App:act(message)
	if type(message) ~= "table" or message.type == nil then return end
	local kind = message.type

	-- A tooltip belongs to the pointer being on its row. Any other message means it left, or
	-- something was pressed, and the frame built for the action must not keep the old label.
	if kind ~= "hoverPlaylist" and self.hoverPlaylist ~= nil then self.hoverPlaylist = nil end

	self:deliver(message)

	-- Whatever the action changed -- a page, a queue, a theme -- is worth a frame now rather
	-- than one at the idle interval, which is longer than the animations it starts.
	self:wake()
end

--- Hands a message to whatever it is for: the overlays from the top down, then the page, then the
--- app's own actions. A light overlay a message passes over is closed by it -- a menu goes away
--- when anything else is pressed -- and a dialog stays. `keep` is a press on an overlay's own
--- panel, which does nothing; `dismiss` is a press beside it, which closes the top one. Not
--- `dispatch`: that is wonderland's, and it is what turns the window's events into messages.
---@param message table
---@return boolean handled
function App:deliver(message)
	local kind = message.type
	if kind == "keep" then return true end
	if kind == "dismiss" then
		local top = self.overlays[#self.overlays]
		if top ~= nil then self:close(top) end
		return true
	end

	local at = #self.overlays
	while at >= 1 do
			local overlay = self.overlays[at]
			local surface = surfaces.overlay(overlay.name)
			if surface.update ~= nil and surface.update(self, overlay, message) then return true end
			if surface.light and self.overlays[at] == overlay then self:close(overlay) end
			at = math.min(at - 1, #self.overlays)
		end

	local page = self:currentPage()
	local surface = surfaces.page(page.kind)
	if surface.update ~= nil and surface.update(self, page, message) then return true end

	local action = actions[kind]
	if action ~= nil then
		action(self, message)
		return true
	end
	return false
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
		if #self.overlays > 0 then
			self:close(self.overlays[#self.overlays])
		elseif self.page.kind == "search" and self.search ~= "" then
			self.search = ""
		elseif self.page.kind ~= "home" then
			self:back()
		end
	elseif key == "/" or (modifiers.ctrl and key == "f") then
		---@type beat.Route
		local searchPage = { kind = "search"}
		self:go(searchPage)
		self:focusField("search", #self.search)
	elseif modifiers.ctrl and key == "o" then
		self:act({ type = "chooseFolder"})
	elseif modifiers.ctrl and key == "," then
		---@type beat.Route
		local route = { kind = "settings"}
		self:go(route)
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

	if self.folderPick ~= nil then
		local chosen, status = Picker.poll(self.folderPick)
		if chosen ~= nil then
			self.folderPick = nil
			self:startScan(chosen)
			changed = true
		elseif status ~= nil then
			self.folderPick = nil
			if status == "no-picker" then
				self:toast("No system folder dialog is available on this machine", "error")
			end
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
	return shell.view(self, window)
end

return App
