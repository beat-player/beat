-- The library the app is showing: the songs a scan found, the ones it added since, and the album
-- order every grid asks for. A scan changes it a track at a time, so what was already drawn must
-- know when that happened rather than poll it every frame; and because the sort is computed over
-- the whole library, it is kept until a track actually changes what is in it.
local names = require("beat.music.names")
local Library = require("beat.music.library")
local LibraryCache = require("beat.app.services.library.cache")
local Signal = require("beat.app.signal")

---@class beat.LibraryService
---@field current beat.Library?
---@field sortedAlbums beat.Album[]?
---@field sortedFor string?
---@field settings beat.SettingsService
---@field emit fun(message: table) # Sends an event to whoever is listening
---@field replaced beat.Signal # Fired with the new library, after the old one is gone
---@field changed beat.Signal # Tracks were added or the scan finished
local LibraryService = {}
LibraryService.__index = LibraryService
LibraryService.needs = { "settings", "options", "emit" }

--- The cache from the last complete scan is loaded here, before anything is scanned again, so a
--- launch draws songs instead of the first-scan page. A scan is only started when there is
--- nothing to draw, which is what `App:init` used to decide.
---@param deps { settings: beat.SettingsService, options: { scan: boolean? }?, emit: fun(message: table) }
---@return beat.LibraryService
function LibraryService.new(deps)
	local self = setmetatable({
		current = nil,
		sortedAlbums = nil,
		sortedFor = nil,
		settings = deps.settings,
		emit = deps.emit,
		replaced = Signal.new(),
		changed = Signal.new(),
	}, LibraryService)

	local options = deps.options or {}
	local root = deps.settings.values.root
	if root ~= nil and options.scan ~= false then self.current = LibraryCache.load(root) end
	return self
end

--- The albums in an order are recomputed from the tracks, so any change to the library drops the
--- one copy that was kept.
---@param self beat.LibraryService
local function dropSorted(self)
	self.sortedAlbums = nil
	self.sortedFor = nil
end

--- A new library for a root, which is what a scan starts from.
---@param root string
function LibraryService:replace(root)
	self.current = Library.new(root)
	dropSorted(self)
	self.replaced:fire(self.current)
	self.emit({ type = "libraryReplaced"})
end

--- Drops the tracks a folder add is about to replace. The folder is scanned again from the
--- filesystem, so what the library held under it is stale the moment the scan starts.
---@param folder string
---@return boolean removed
function LibraryService:forgetFolder(folder)
	local library = self.current
	if library == nil then return false end
	local removed = library:removeUnder(folder)
	if removed then
		dropSorted(self)
		self.changed:fire()
	end
	return removed
end

--- A track the scan read. The caller guards the call, because one unreadable file must not stop
--- the scan; the change is announced only once `add` returned, so a listener never sees a
--- half-built track.
---@param info table
---@param entry table
---@param cover any
---@param coverCache string?
---@return beat.Track? track, boolean? gainedCover
function LibraryService:add(info, entry, cover, coverCache)
	local track, gainedCover = self.current:add(info, entry, cover, coverCache)
	dropSorted(self)
	self.changed:fire()
	return track, gainedCover
end

--- The scan is over: album track lists and durations are final now.
function LibraryService:finish()
	self.current:finish()
	dropSorted(self)
	self.changed:fire()
end

--- Writes the library to its cache. Called when a scan finishes, not on every track.
---@return boolean
---@return string? err
function LibraryService:save()
	return LibraryCache.save(assert(self.current))
end

--- The albums in an order, computed once per order until the library changes. `recent` is the
--- library's own list reversed, so it is copied rather than sorted.
---@param order string
---@return beat.Album[]
function LibraryService:sorted(order)
	if self.sortedAlbums ~= nil and self.sortedFor == order then return self.sortedAlbums end
	local library = self.current
	if library == nil then return {} end

	local albums = {}
	for _, album in ipairs(library.albums) do albums[#albums + 1] = album end

	if order == "artist" then
		table.sort(albums, function(a, b)
			local aa, ba = names.fold(a.artist), names.fold(b.artist)
			if aa ~= ba then return aa < ba end
			return names.fold(a.title) < names.fold(b.title)
		end)
	elseif order == "year" then
		table.sort(albums, function(a, b)
			local ay, by = a.year or 0, b.year or 0
			if ay ~= by then return ay > by end
			return names.fold(a.title) < names.fold(b.title)
		end)
	elseif order == "recent" then
		albums = {}
		for at = #library.recent, 1, -1 do albums[#albums + 1] = library.recent[at] end
	elseif order == "modified" then
		table.sort(albums, function(a, b)
			if a.modified ~= b.modified then return a.modified > b.modified end
			return names.fold(a.title) < names.fold(b.title)
		end)
	end

	self.sortedAlbums = albums
	self.sortedFor = order
	return albums
end

return LibraryService
