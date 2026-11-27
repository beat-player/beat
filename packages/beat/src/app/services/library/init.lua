-- The library the app is showing: the songs a scan found, the ones it added since, and the album
-- order every grid asks for. A scan changes it a track at a time, so what was already drawn must
-- know when that happened rather than poll it every frame; and because the sort is computed over
-- the whole library, it is kept until the library's version says something changed. Keying it on
-- the version rather than dropping it on every add means a page open while a scan runs sorts at
-- most once per change the scan has made, not once per track it added.
local names = require("beat.music.names")
local Library = require("beat.music.library")
local LibraryCache = require("beat.app.services.library.cache")
local Signal = require("beat.app.signal")
local threading = require("threading")
local time = require("wonderland.time")
local Log = require("beat.log")

-- How much of a loading cache one tick takes into the library. The file is parsed and its records
-- are unpacked on a thread, but building the library from them -- interning tags, grouping albums
-- -- is this thread's, and a large library is thousands of records: a share of a frame per tick
-- keeps the first frame and the frames after it from waiting for all of it.
local LOAD_BUDGET = 0.003

-- Records one message from the loading thread carries. A message is copied across with
-- `string.buffer` when it is popped, so its size is what one tick's decode and adds cost: 16
-- records is a few milliseconds of unpacking and interning with room left for the frame.
local LOAD_BATCH = 16

-- How much of a frame one tick of the sort that closes a load or a scan may take. The sort of a
-- few thousand tracks is a few hundred small sorts and two name sorts; a share of a frame a tick
-- closes it across the ticks that follow rather than in the one that finished the last batch.
local FINISH_BUDGET = 0.004

-- How many times a second the frames behind the shell are rebuilt while the cache is taken in.
-- Every batch would be one: a present is the view, the layout and the draw of the page, which is
-- more than the batches themselves cost, and a page showing songs every eighth of a second looks
-- the same as one showing them every tick. The end of the load is reported regardless, so the
-- last state is always drawn.
local LOAD_CHANGES_PER_SECOND = 8
local LOAD_CHANGE_INTERVAL = 1 / LOAD_CHANGES_PER_SECOND

-- How often a page already drawing the library may re-sort it while the cache is still coming in.
-- The album order is kept until the sort that closes the load: a page that re-sorted for every
-- batch was the difference between an ingest tick and a frame.
local LOAD_SORT_INTERVAL = 1

--- A load whose service went away while its thread was still reading. The handle is kept because a
--- `threading.Handle` that is dropped is never joined, and the channel is kept because the thread
--- may not have attached to it yet: letting the last reference go first would leave it with an
--- address of freed memory.
---@class beat.AbandonedLoad
---@field handle threading.Handle
---@field events threading.Channel
---@type beat.AbandonedLoad[]
local abandoned = {}

local function reap()
	for at = #abandoned, 1, -1 do
		local group = abandoned[at]
		if group.handle:done() then
			pcall(group.handle.join, group.handle)
			group.events:close()
			table.remove(abandoned, at)
		end
	end
end

---@class beat.LibraryService: beat.Service
---@field current beat.Library?
---@field outdated string[]? # Tracks an older cache may have grouped by folder, which a scan reads again
---@field sortedAlbums beat.Album[]?
---@field sortedFor string?
---@field sortedVersion number? # The library version `sortedAlbums` was computed for
---@field root string? # The root whose cache is being read, until it is in
---@field loading boolean # Whether the cache from the last scan is still being read
---@field loadStarted boolean # Whether the read was started, by a tick or by `load`
---@field loadHandle threading.Handle? # The thread reading the cache, while it runs
---@field loadEvents threading.Channel? # Its messages, until the library is complete
---@field finishing boolean # Whether the sort that closes the load or scan is still running
---@field changeAt number? # When the loading library last asked the app for a frame
---@field sortedAt number? # When the album order `sortedAlbums` was computed
---@field settings beat.SettingsService
---@field emit fun(message: table) # Sends an event to whoever is listening
---@field replaced beat.Signal # Fired with the new library, after the old one is gone
---@field changed beat.Signal # Tracks were added or the scan finished
---@field finished beat.Signal # Fired with the library once a scan is over, after `changed`
---@field loaded beat.Signal # Fired with the library once the cached one is in, or nil when there was none
local LibraryService = {}
LibraryService.__index = LibraryService
LibraryService.needs = { "settings", "options", "emit" }

--- The albums in an order are recomputed from the tracks, so any change to the library drops the
--- one copy that was kept.
---@param self beat.LibraryService
local dropSorted

--- The cache from the last complete scan is read after the first frame rather than in here, so a
--- launch draws its shell and the page loaded or empty-scanning state before the file is parsed.
--- `step` starts the read and takes it in a batch a tick; `load` is for a caller that needs it now.
--- A restart hands the library it already has through `options.library`, since the root and the
--- playlist switches it was read for are still the same.
---@param deps { settings: beat.SettingsService, options: { scan: boolean?, library: { current: beat.Library, outdated: string[]? }? }?, emit: fun(message: table) }
---@return beat.LibraryService
function LibraryService.new(deps)
	local self = setmetatable({
		current = nil,
		outdated = nil,
		sortedAlbums = nil,
		sortedFor = nil,
		sortedVersion = nil,
		sortedAt = nil,
		root = nil,
		loading = false,
		loadStarted = false,
		finishing = false,
		changeAt = nil,
		loadHandle = nil,
		loadEvents = nil,
		settings = deps.settings,
		emit = deps.emit,
		replaced = Signal.new(),
		changed = Signal.new(),
		finished = Signal.new(),
		loaded = Signal.new()
	}, LibraryService)

	local options = deps.options or {}
	local root = deps.settings.values.root
	local reused = options.library
	if reused ~= nil and reused.current ~= nil and reused.current.root == root then
		self.current = reused.current
		self.outdated = reused.outdated
	elseif root ~= nil and options.scan ~= false then
		self.root = root
		self.loading = true
	end
	return self
end

--- Whether the cache from the last scan is still being read. What depends on the library -- a scan
--- deciding whether one is needed, the session restored from the queue it names -- asks this
--- rather than treating an empty library as a library with no songs.
---@return boolean
function LibraryService:isLoading()
	return self.loading
end

--- Starts the thread that reads the cache. Its function closes over strings only, which is what a
--- thread's upvalues may be.
function LibraryService:startLoad()
	local root = self.root
	if root == nil then
		self.loading = false
		return
	end
	self.loadStarted = true
	reap()

	local events = threading.channel()
	local address = events:address()
	local file = LibraryCache.file()
	local ok, handle = pcall(threading.spawn, function()
		require("beat.app.services.library.cache").pour(file, root, address, LOAD_BATCH)
	end)
	if not ok then
		Log.write("error", "the library cache could not be read on a thread: " .. tostring(handle))
		events:close()
		self.loading = false
		self.loaded:fire(nil)
		return
	end

	self.loadHandle = handle --[[@as threading.Handle]]
	self.loadEvents = events
end

--- Adds a message's records to the library, a batch of the loading thread's output at a time.
--- The first batch makes the library, so a page drawing while the read goes on shows the songs it
--- has so far rather than the first-scan page the whole way through.
---@param records table[]
---@return boolean changed
function LibraryService:addRecords(records)
	if not self.loading then return false end
	local library = self.current
	if library == nil then
		library = Library.new(assert(self.root))
		self.current = library
	end
	for at = 1, #records do library:addCached(records[at]) end
	return true
end

--- The read is over: the library has every record the cache held (or none, for a cache the scan
--- wrote before anything was in it), and the scan and the session can go on from it.
---@param outdated string[]?
---@param valid boolean? # False when the read ended without saying whether its cache was a cache
function LibraryService:completeLoad(outdated, valid)
	local library = self.current
	if valid == false then
		-- The read did not finish (its thread went away, or the file stopped being a cache), so
		-- what it had pushed is not a library a scan can be skipped against: a scan starts from
		-- nothing rather than from half a cache.
		library = nil
		self.current = nil
	end
	if library == nil and valid ~= false then
		-- A cache with no records still says what the root is, and the scan need not run again.
		library = Library.new(assert(self.root))
		self.current = library
	end
	local events = self.loadEvents
	self.loading = false
	self.loadEvents = nil
	if self.loadHandle ~= nil then
		pcall(self.loadHandle.join, self.loadHandle)
		self.loadHandle = nil
	end
	if events ~= nil then events:close() end
	if library ~= nil then
		-- The sort of what was read is not run here: it is longer than the frame this tick follows
		-- into, and the library is complete without it. `step` finishes it over the next few ticks
		-- and announces it then, with the order the page draws. Announcing the records before that
		-- would build the page once for an order it is about to replace, which is the frame this
		-- defers.
		self.outdated = outdated
		self.finishing = true
	end
	self.loaded:fire(library)
end

--- Reads whatever the thread has pushed, until the tick's share of a frame is spent.
---@param deadline number
---@return boolean changed
function LibraryService:pumpLoad(deadline)
	local events = self.loadEvents
	if events == nil then return false end

	local changed = false
	while true do
		local message = events:pop()
		if message == nil then break end
		local kind = message.kind
		if kind == "records" then
			changed = self:addRecords(message.records) or changed
			if time.now() >= deadline then break end
		elseif kind == "done" then
			-- The records are all in, but the sort that closes them has not run: the page is built
			-- once when it has, not for an order the next ticks replace.
			self:completeLoad(message.outdated)
			return false
		else
			-- Missing, unreadable or written for another root: there is no library to show, and a
			-- scan decides what to do from an empty one. An unreadable file was logged where it
			-- failed.
			self:completeLoad(nil, false)
			return true
		end
	end
	return changed
end

--- The first tick after the first frame starts the read and takes its first batches. The service
--- stays at the frame rate until the library is in, because the pages behind the shell are drawing
--- the songs as they arrive.
---@param now number
---@return boolean? changed
---@return boolean? busy
function LibraryService:step(now)
	if self.finishing then
		local done = self:finishStep(now + FINISH_BUDGET)
		if done then return true end
		return false, true
	end
	if not self.loading then return end
	if not self.loadStarted then
		self:startLoad()
		if self.loading then return false, true end
		return false
	end

	local changed = self:pumpLoad(now + LOAD_BUDGET)
	if self.loading then
		local handle = self.loadHandle
		-- The thread always ends with a message or a closed channel; a handle that has finished
		-- with nothing left to read is a read that could not say what happened.
		if handle ~= nil and handle:done() and self.loadEvents ~= nil and self.loadEvents:count() == 0 then
			self:completeLoad(nil, false)
			return true
		end
		-- The batches were taken in this tick whether or not the frame is rebuilt for them: what is
		-- spaced out is the present, not the ingest.
		if changed then changed = self:paceChange(now) end
		return changed, true
	end
	self.changeAt = nil
	return changed
end

--- Whether the loading library may ask for a frame now, at most `LOAD_CHANGES_PER_SECOND` times.
---@param now number
---@return boolean
function LibraryService:paceChange(now)
	local at = self.changeAt
	if at ~= nil and now - at < LOAD_CHANGE_INTERVAL then return false end
	self.changeAt = now
	return true
end

--- Takes the next share of the sort that closes a load or a scan, and, once it is done, tells the
--- app the library changed and that the scan is over: what the sort produces is the album order
--- and the album covers, so a page rebuilt before it would draw them the old way and again after.
---@param deadline number
---@return boolean done
function LibraryService:finishStep(deadline)
	local library = self.current
	if library == nil then
		self.finishing = false
		return true
	end
	if not library:finishStep(deadline) then return false end
	self.finishing = false
	self.outdated = nil
	dropSorted(self)
	self.changed:fire()
	self.finished:fire(library)
	return true
end

--- Reads the cache to completion on this thread. Tests and the benchmark need the library the
--- moment they ask for it; a launch lets `step` do it after the first frame.
---@return beat.Library?
function LibraryService:load()
	if not self.loading then return self.current end
	if not self.loadStarted then
		self.loadStarted = true
		local library, outdated = LibraryCache.load(assert(self.root))
		self.loading = false
		self.current = library
		if library ~= nil then
			self.outdated = outdated
			dropSorted(self)
			self.changed:fire()
			self.finished:fire(library)
		end
		self.loaded:fire(library)
		return library
	end

	if self.loadHandle ~= nil then
		pcall(self.loadHandle.join, self.loadHandle)
		self.loadHandle = nil
	end
	if self.loadEvents ~= nil then self:pumpLoad(math.huge) end
	if self.loading then self:completeLoad(nil, false) end
	while self.finishing do self:finishStep(math.huge) end
	return self.current
end

--- The app has no more use for this load: a restart, or a scan that replaces the library while
--- the cache is still being read. The thread is told by the closed channel at its next push, and
--- joined later rather than holding a frame or a restart still.
function LibraryService:cancelLoad()
	local events, handle = self.loadEvents, self.loadHandle
	self.loadEvents, self.loadHandle = nil, nil
	self.loading = false
	self.loadStarted = false
	self.finishing = false
	self.changeAt = nil
	if events ~= nil then
		events:close()
		if handle ~= nil then
			if handle:done() then
				pcall(handle.join, handle)
			else
				abandoned[#abandoned + 1] = { handle = handle, events = events }
			end
		end
	end
end

--- The app is being set up again: nothing will read this load any more. A sort still running is
--- finished here rather than handed to the app that replaces this one -- the library it keeps is
--- handed over as it is, and a library whose albums are half ordered would stay that way.
function LibraryService:close()
	-- `cancelLoad` drops the finish state with everything else the load owned, so what was running
	-- is read before it: the sort belongs to the library, which outlives this service.
	local finishing = self.finishing
	self:cancelLoad()
	if finishing then
		if self.current ~= nil then self.current:finish() end
		dropSorted(self)
	end
end

--- The albums in an order are recomputed from the tracks, so any change to the library drops the
--- one copy that was kept.
---@param self beat.LibraryService
function dropSorted(self)
	self.sortedAlbums = nil
	self.sortedFor = nil
	self.sortedVersion = nil
	self.sortedAt = nil
end

--- A new library for a root, which is what a scan starts from.
---@param root string
function LibraryService:replace(root)
	if self.loading then self:cancelLoad() end
	self.finishing = false
	self.current = Library.new(root)
	self.outdated = nil
	dropSorted(self)
	self.replaced:fire(self.current)
	self.emit({ type = "libraryReplaced" })
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
---@param info treble.audio.Inspect
---@param entry { path: string, dir: string, name: string, ext: string, modifyTime: number?, key: string? }
---@param cover string?
---@param coverCache string?
---@return beat.Track? track, boolean? gainedCover
function LibraryService:add(info, entry, cover, coverCache)
	local track, gainedCover = self.current:add(info, entry, cover, coverCache)
	-- The sort is keyed on the library's version, which `add` has just raised: it is not dropped
	-- here, or a page open during a scan would re-sort for every track the scan adds.
	self.changed:fire()
	return track, gainedCover
end

--- The records a scan can take from what is already loaded instead of reading the files again.
--- Tracks an older cache could not vouch for are left out, so the scan reads those again.
---@return table[]?
function LibraryService:records()
	local library = self.current
	if library == nil then return nil end

	local skip = nil
	if self.outdated ~= nil then
		skip = {}
		for _, file in ipairs(self.outdated) do skip[file] = true end
	end

	local records = {}
	for _, track in ipairs(library.tracks) do
		if skip == nil or not skip[track.path] then
			local album = library:album(track.albumId)
			records[#records + 1] = LibraryCache.pack(track, album?.key)
		end
	end
	return records
end

--- A track the scan took from the library already loaded rather than read again.
---@param record table
---@return beat.Track? track
---@return boolean? gainedCover
function LibraryService:addCached(record)
	local track, gainedCover = self.current:addCached(record)
	self.changed:fire()
	return track, gainedCover
end

--- The scan is over: album track lists and durations are final now. The sort itself runs a slice
--- a tick (`finishStep`), because sorting a few thousand tracks is longer than a frame; a caller
--- that needs the library sorted before it goes on -- a test, a cache read on this thread -- calls
--- `current:finish()` itself, which is the same sort to the end.
function LibraryService:finish()
	if self.current == nil or self.finishing then return end
	self.finishing = true
	self.outdated = nil
	dropSorted(self)
end

--- Writes the library to its cache. Called when a scan finishes, not on every track.
---@return boolean
---@return string? err
function LibraryService:save()
	return LibraryCache.save(assert(self.current))
end

--- The folded titles and artists of a list of albums, made once for a sort to read instead of
--- folding both names inside every comparison. An order is computed once per library change, so
--- these are made again each time rather than kept: a second copy of every title is not worth the
--- heap a library holds for as long as it runs.
---@param albums beat.Album[]
---@return table<beat.Album, string> titles
---@return table<beat.Album, string> artists
local function folded(albums)
	local titles, artists = {}, {}
	for _, album in ipairs(albums) do
		titles[album] = names.fold(album.title)
		artists[album] = names.fold(album.artist)
	end
	return titles, artists
end

-- The folded names the current sort is reading. A comparator is a function with no arguments of
-- its own -- the names are made for the sort and read by all three -- and one made inside the sort
-- would close the names as upvalues on the frame that draws a page.
local sortTitles = {}
local sortArtists = {}

local function byArtist(a, b)
	local aa, ba = sortArtists[a], sortArtists[b]
	if aa ~= ba then return aa < ba end
	return sortTitles[a] < sortTitles[b]
end

local function byYear(a, b)
	local ay, by = a.year or 0, b.year or 0
	if ay ~= by then return ay > by end
	return sortTitles[a] < sortTitles[b]
end

local function byModified(a, b)
	if a.modified ~= b.modified then return a.modified > b.modified end
	return sortTitles[a] < sortTitles[b]
end

--- The albums in an order, computed once per order until the library changes. `recent` is the
--- library's own list reversed, so it is copied rather than sorted.
---
--- While the cache is coming in, the library version changes with every batch: the order a page
--- already has is kept for a second rather than sorted again for every frame, which is what a page
--- drawing during a load used to cost. The sort that closes the load drops it, so the first frame
--- after the cache is in draws the real order.
---@param order string
---@return beat.Album[]
function LibraryService:sorted(order)
	local library = self.current
	if library == nil then return {} end
	local known = self.sortedAlbums
	if known ~= nil and self.sortedFor == order then
		if self.sortedVersion == library.version then return known end
		if self.loading then
			local at = self.sortedAt
			if at ~= nil and time.now() - at < LOAD_SORT_INTERVAL then return known end
		end
	end

	local albums = {}
	if order == "recent" then
		for at = #library.recent, 1, -1 do albums[#albums + 1] = library.recent[at] end
		self.sortedAlbums = albums
		self.sortedFor = order
		self.sortedVersion = library.version
		self.sortedAt = time.now()
		return albums
	end

	for _, album in ipairs(library.albums) do albums[#albums + 1] = album end

	local titles, artists = folded(albums)
	sortTitles, sortArtists = titles, artists
	if order == "artist" then
		table.sort(albums, byArtist)
	elseif order == "year" then
		table.sort(albums, byYear)
	elseif order == "modified" then
		table.sort(albums, byModified)
	end

	self.sortedAlbums = albums
	self.sortedFor = order
	self.sortedVersion = library.version
	self.sortedAt = time.now()
	return albums
end

return LibraryService
