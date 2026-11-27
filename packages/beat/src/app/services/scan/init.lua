-- Reading a folder into the library: where the library comes from, the job that walks it, and
-- the two cards over the corner that say how far it has got. The scan is the only thing that makes
-- a library appear, so it also owns the folder the library was chosen from and the question the
-- first launch asks -- everything a view needs to say "no folder yet" comes from here.
local Picker = require("beat.app.services.scan.picker")
-- The job that walks a folder is read when a scan starts rather than when the app does: a launch
-- that only browses the cached library never needs it.
local function scanJob() return require("beat.app.services.scan.job") end
local path = require("path")
local time = require("wonderland.time")
local Log = require("beat.log")
local platform = require("beat.platform")
local LibraryCache = require("beat.app.services.library.cache")

-- How much of a scan's output one tick takes into the library. A fast local scan can produce a
-- whole library in a fraction of a second: taking it a fixed handful of tracks a tick makes the
-- scan last as many frames as the library has tracks, and taking all of it in one tick holds a
-- frame for as long as the reading and adding take. A share of a frame per tick keeps both ends
-- bounded, and the batch cap keeps one add loop from growing without limit on a slow machine.
local INGEST_BUDGET = 0.002
-- Messages one poll may decode. With the budget checked between polls, the batch is what bounds
-- how far a single poll can run past it: a message is a track with its tags, and a hundred is
-- several milliseconds before the clock is asked again.
local INGEST_BATCH = 32

-- Seconds of cache writing one tick takes after a scan finishes. The library's whole cache is
-- encoded and written then; doing it in the tick that finishes the scan holds a frame for as long
-- as the library is large, so it is spread over the ticks that follow.
local SAVE_BUDGET = 0.002

-- A save has nothing on screen depending on it: it takes a slice every thirtieth of a second
-- rather than making the ticker run at the display's rate for as long as it lasts.
local SAVE_TICK = 0.03

-- While a scan runs, the page behind it is rebuilt at most this often. A scan adds tracks every
-- tick, and a scan of a fast local folder produces thousands a second: rebuilding the view sixty
-- times a second for a progress count nobody can read is work with no picture to show for it.
-- Endings -- the last track, the folder chosen, a failure -- are reported at once.
local SCAN_REBUILD_INTERVAL = 1 / 8

-- Showing a permission dialog leaves the app waiting for a person, not for a frame: asking the
-- system whether access was granted is a JNI call, and once a second is plenty.
local ACCESS_INTERVAL = 1

-- How often a folder dialog that is still open is asked for its answer. The chooser runs on a
-- worker thread on Linux, so this is a file check, not a UI-thread wait.
local PICK_INTERVAL = 0.25

---@class beat.ScanSummary
---@field tracks number
---@field albums number
---@field skipped number
---@field at number

---@class beat.ScanService: beat.Service
---@field job beat.ScanJob? # The job reading the folder, while there is one
---@field addJob beat.ScanJob? # The job reading one folder into the existing library, while there is one
---@field addFolderPath string? # The folder that job is reading
---@field pick beat.FolderPick? # The system folder dialog, while it is open
---@field pickRequest { reply: string? }? # Who the open dialog's answer goes to; nil reply is a library root
---@field pickQueue { reply: string? }[] # Dialogs asked for while one was open
---@field islandOpen boolean # Whether the reading island was left showing
---@field summary beat.ScanSummary? # What the last finished scan added, until it is dismissed
---@field skipped number # Files the last finished scan could not read
---@field errors { path: string, message: string }[]
---@field awaitingAccess boolean? # Asked the system for access to the music folder; the scan starts once it is granted
---@field accessCheckedAt number? # When `canReadMusic` was last asked while waiting for access
---@field saving beat.LibraryCacheWriter? # The cache being written after a scan, a slice a tick
---@field savingFor "scan"|"add"? # Which finished job the write belongs to
---@field pendingAdd { tracks: number, skipped: number }? # What the folder add says once its cache is written
---@field reportedAt number? # When the running scan last asked for a rebuilt view
---@field settings beat.SettingsService
---@field library beat.LibraryService
---@field covers beat.CoversService
---@field playback beat.PlaybackService
---@field toasts beat.ToastsService
---@field emit fun(message: table)
---@field window fun(): winit.Window? # The window the native dialog is shown in
---@field options { scan: boolean? }
local Scan = {}
Scan.__index = Scan
Scan.needs = { "settings", "library", "covers", "playback", "toasts", "emit", "window", "options" }

---@param deps {
--- settings: beat.SettingsService,
--- library: beat.LibraryService,
--- covers: beat.CoversService,
--- playback: beat.PlaybackService,
--- toasts: beat.ToastsService,
--- emit: fun(message: table),
--- window: fun(): winit.Window?,
--- options: { scan: boolean? },
--- }
---@return beat.ScanService
function Scan.new(deps)
	return setmetatable(
		{
			job = nil,
			addJob = nil,
			addFolderPath = nil,
			pick = nil,
			pickRequest = nil,
			pickQueue = {},
			islandOpen = true,
			summary = nil,
			skipped = 0,
			errors = {},
			accessCheckedAt = nil,
			saving = nil,
			savingFor = nil,
			pendingAdd = nil,
			reportedAt = nil,
			settings = deps.settings,
			library = deps.library,
			covers = deps.covers,
			playback = deps.playback,
			toasts = deps.toasts,
			emit = deps.emit,
			window = deps.window,
			options = deps.options or {}
		},
		Scan
	)
end

--- A root that was never chosen is the first launch: the folder browser asks for one.
---@return boolean
function Scan:needsFolder()
	return self.settings.values.root == nil
end

--- How far the running scan has got, from nothing to done. The two cards that draw it and the
--- home screen's placeholder all ask the scan rather than working the fraction out themselves.
---@return number
function Scan:fraction()
	local job = self.job
	if job == nil then return 0 end
	local progress = job:progress()
	if progress.files <= 0 then return 0 end
	return math.max(0, math.min(1, progress.inspected / progress.files))
end

--- A launch draws the last complete scan, so it only scans when there is nothing to draw; a
--- manual Rescan replaces what is there. `App:init` used to decide this before anything had a
--- chance to draw. A cache from the previous layout can still be drawn, but the tracks it may
--- have grouped by folder are read again by a scan that takes the rest from the cache.
---@param granted boolean? # The caller just found access granted; do not ask the system again
function Scan:resume(granted)
	local root = self.settings.values.root
	if root == nil or self.options.scan == false then return end
	if self.library.current ~= nil and (self.library.outdated == nil or #self.library.outdated == 0) then return end
	-- A phone keeps the music folder behind a permission. Without it the folder reads as empty,
	-- and a scan of it would save an empty library over the one the listener is about to allow.
	if granted ~= true and not platform.canReadMusic() then
		self.awaitingAccess = true
		self.accessCheckedAt = time.now()
		platform.requestMusicAccess()
		return
	end
	self:start(root)
end

--- A new library for a root. What was playing is from the old one, so it stops; every cover on
--- screen belongs to an album that is gone, so they are released. The app goes home with the
--- history forgotten, because every page behind the scan showed the library it replaced.
---
--- A scan of the same root takes the records of the library already loaded, so an inspector can
--- answer for a file whose modification time has not changed without opening it. A new root has
--- nothing in common with the old library, and starts from nothing.
---@param root string
function Scan:start(root)
	Picker.cancel(self.pick)
	self.pick = nil
	if self.job ~= nil then self.job:cancel() end
	-- A cache write of the library this scan replaces has no reader left: drop it rather than let
	-- it rename its temp file over the cache the new scan will write.
	self:abortSave()
	self.pendingAdd = nil
	self.reportedAt = nil

	local current = self.library.current
	local known = nil
	if current ~= nil and path.normalize(current.root) == path.normalize(root) then
		known = self.library:records()
	end

	self.playback:reset()
	self.covers:releaseAll()
	self.library:replace(root)
	self.job = scanJob().start(root, known)
	self.islandOpen = true
	self.summary = nil
	self.skipped = 0
	self.errors = {}

	self.settings.values.root = root
	self.settings:save()

	self.emit({ type = "reset", page = { kind = "home" } })
end

--- Adds one folder to the library that is already there. The tracks under it are dropped first,
--- so a folder downloaded again replaces what the library had rather than appearing twice. The
--- rest of the library -- and what is playing, and the queue -- is left alone.
---@param folder string
function Scan:addFolder(folder)
	if self.job ~= nil then
		self.toasts:show("Wait for the library scan to finish", "error")
		return
	end
	if self.addJob ~= nil then
		self.addJob:cancel()
		self.addJob:close()
		self.addJob = nil
	end

	local library = self.library
	if library.current == nil then
		-- A plugin can download before a library exists. The library still needs a root, and the
		-- settings' one is what a later full scan would use; the folder itself is the fallback.
		local root = self.settings.values.root or folder
		library:replace(root)
		self.settings.values.root = root
		self.settings:save()
	end

	library:forgetFolder(folder)
	self.addFolderPath = folder
	self.addJob = scanJob().start(folder)
end

--- Starts the folder dialog, or waits for the one already open. A request with a reply is a
--- plugin's; one without is the library's own root choice.
---@param request { reply: string? }
function Scan:startPick(request)
	if self.pick ~= nil then
		self.pickQueue[#self.pickQueue + 1] = request
		return
	end

	self.pickRequest = request
	local title = request.reply ~= nil and "Choose a folder" or "Choose music folder"
	self.pick = Picker.start(self.window(), { title = title })
end

--- The next dialog asked for while one was open, if any.
function Scan:nextPick()
	local request = table.remove(self.pickQueue, 1)
	if request ~= nil then self:startPick(request) end
end

--- The tracks a job has produced, into the library, until the tick's share of a frame is spent.
--- The inspectors may have pushed them long ago: what bounds a tick is the reading and the adding,
--- not how much output is waiting.
---@param job beat.ScanJob
---@param errors { path: string, message: string }[]?
---@return boolean changed
function Scan:ingest(job, errors)
	local library = self.library
	local changed = false
	local deadline = time.now() + INGEST_BUDGET

	while true do
		local events, progressed = job:poll(INGEST_BATCH)
		if progressed then changed = true end
		for _, event in ipairs(events) do
			---@cast event table
			if event.type == "track" and library.current ~= nil then
				self:addTrack(event, errors)
				changed = true
			elseif event.type == "reused" and library.current ~= nil then
				-- A file the scan did not open: the library's own record for it, which a cache
				-- stored and the scan carried forward.
				local ok, err = pcall(library.addCached, library, event.record)
				if not ok then
					self.toasts:show("Could not read a scanned track", "error")
					if errors ~= nil then
						local record = event.record
						errors[#errors + 1] = {
							path = type(record) == "table" and tostring(record.path) or "a track",
							message = tostring(err)
						}
					end
				end
				changed = true
			end
		end

		if #events == 0 or time.now() >= deadline then break end
	end

	return changed
end

--- One inspected file into the library. A full scan also keeps the failures for the settings
--- screen; a folder added by a plugin only says so in a toast.
---@param event table
---@param errors { path: string, message: string }[]?
function Scan:addTrack(event, errors)
	local library = self.library
	if library.current == nil then return end

	local track, gainedCover
	-- One unreadable file must not stop the scan: it is a toast and a line in the settings
	-- screen's list, not the end of the folder.
	local ok, err = pcall(function()
		track, gainedCover = library:add(event.info, event.entry, event.cover, event.coverCache)
	end)
	if not ok then
		self.toasts:show("Could not read a scanned track", "error")
		if errors ~= nil then
			errors[#errors + 1] = { path = event.entry.path, message = tostring(err) }
		end
	elseif track ~= nil and (track.hasPicture or gainedCover) then
		self.covers:forget(track.albumId)
	end
end

--- A cache write still settling is dropped: a newer save replaces it, and two writers on one temp
--- file would interleave. The library's next save writes whatever the scan has made by then. A
--- pending folder add's result is left alone: the save about to start is the one that reports it.
function Scan:abortSave()
	local writer = self.saving
	if writer ~= nil then writer:abort() end
	self.saving = nil
	self.savingFor = nil
end

--- Starts writing the library's cache, a slice a tick. `kind` says what to do once the disk has
--- it: a full scan only logs a failure, while a folder add reports to the page and the listener.
---@param kind "scan"|"add"
function Scan:startSave(kind)
	self:abortSave()
	local library = self.library.current
	if library == nil then return end

	local writer, err = LibraryCache.openSave(library)
	if writer == nil then
		self.savingFor = kind
		self:saveFailed(err)
		return
	end

	self.saving = writer
	self.savingFor = kind
end

--- The page shows the folder add's result once the cache agrees: the listener is told once, after
--- the write, and the toasts say what the folder brought.
function Scan:finishAdd()
	local added = self.pendingAdd
	self.pendingAdd = nil
	self.emit({ type = "libraryChanged" })
	if added == nil then return end

	local tracks = added.tracks
	self.toasts:show("Added " .. tracks .. " track" .. (tracks == 1 and "" or "s") .. " to the library")
	if added.skipped > 0 then
		self.toasts:show(added.skipped .. " files could not be read", "error")
	end
end

--- The cache writer finished. A full scan has nothing left to say; a folder add tells the page
--- and the listener only now, because they read the cache and the library must be on disk first.
function Scan:saveFinished()
	local kind = self.savingFor
	self.saving = nil
	self.savingFor = nil
	if kind == "add" then self:finishAdd() end
end

---@param err string?
function Scan:saveFailed(err)
	local kind = self.savingFor
	self.saving = nil
	self.savingFor = nil
	if kind == "add" then
		self.toasts:show(err or "Could not save the library", "error")
		-- The folder is in the library whether or not the disk took it: the page still shows it.
		self:finishAdd()
	else
		Log.write("error", "library cache could not be written: " .. tostring(err))
	end
end

Scan.on = {
	--- A root chosen for the first time, or one a page asked for: the library it reads replaces
	--- whatever was showing.
	---@param self beat.ScanService
	---@param message beat.StartScanMessage
	startScan = function(self, message) self:start(message.root) end,

	--- A manual rescan of the root already chosen. A launch with no root has nothing to rescan.
	---@param self beat.ScanService
	---@param message beat.RescanMessage
	rescan = function(self, message)
		local root = self.settings.values.root
		if root ~= nil then self:start(root) end
	end,

	---@param self beat.ScanService
	---@param message beat.ChooseFolderMessage
	chooseFolder = function(self, message) self:startPick({}) end,

	---@param self beat.ScanService
	---@param message beat.PickFolderMessage
	pickFolder = function(self, message)
		if type(message.reply) ~= "string" or message.reply == "" then
			self.toasts:show("A folder pick needs a reply message type", "error")
		else
			self:startPick({ reply = message.reply })
		end
	end,

	---@param self beat.ScanService
	---@param message beat.LibraryAddFolderMessage
	libraryAddFolder = function(self, message)
		if type(message.path) ~= "string" or message.path == "" then
			self.toasts:show("Adding a folder needs a path", "error")
		else
			self:addFolder(message.path)
		end
	end,

	---@param self beat.ScanService
	---@param message beat.CancelScanMessage
	cancelScan = function(self, message)
		if self.job ~= nil then
			self.job:cancel()
			self.job = nil
			self.islandOpen = false
			self.toasts:show("Scan cancelled")
		end
	end,

	---@param self beat.ScanService
	---@param message beat.HideScanIslandMessage
	hideScanIsland = function(self, message) self.islandOpen = false end,

	---@param self beat.ScanService
	---@param message beat.ShowScanIslandMessage
	showScanIsland = function(self, message) self.islandOpen = true end,

	---@param self beat.ScanService
	---@param message beat.DismissScanSummaryMessage
	dismissScanSummary = function(self, message) self.summary = nil end
}

--- The dialog is modal, so its answer is read back from a file; the tracks arrive through the
--- scan job's channel, a batch a tick, so a fast local scan cannot make one frame add thousands of
--- rows.
function Scan:step(now)
	local changed = false
	-- What the page must be built again for at once: something a person is waiting on, not a
	-- scan's progress, which is coalesced below.
	local urgent = false

	if self.awaitingAccess then
		local checkedAt = self.accessCheckedAt
		if checkedAt == nil or now - checkedAt >= ACCESS_INTERVAL then
			self.accessCheckedAt = now
			if platform.canReadMusic() then
				self.awaitingAccess = false
				self.accessCheckedAt = nil
				self:resume(true)
				changed = true
				urgent = true
			end
		end
	end

	if self.pick ~= nil then
		local chosen, status = Picker.poll(self.pick)
		if chosen ~= nil then
			local request = self.pickRequest
			self.pick = nil
			self.pickRequest = nil
			if request ~= nil and request.reply ~= nil then
				self.emit({ type = request.reply, path = chosen })
			else
				self:start(chosen)
			end
			self:nextPick()
			changed = true
			urgent = true
		elseif status ~= nil then
			local request = self.pickRequest
			self.pick = nil
			self.pickRequest = nil
			if status == "no-picker" then
				self.toasts:show("No system folder dialog is available on this machine", "error")
			end
			if request ~= nil and request.reply ~= nil then
				self.emit({ type = request.reply, path = nil })
			end
			self:nextPick()
			changed = true
			urgent = true
		end
	end

	local job = self.job
	if job ~= nil then
		local library = self.library
		if self:ingest(job, self.errors) then changed = true end

		if job:isDone() and not job:hasPending() then
			local progress = job:progress()
			if progress.phase == "done" then
				---@cast library.current -nil
				library:finish()
				-- A scan can have made good on a cover this page had found missing -- a cache
				-- directory that was cleaned, say -- so the placeholders left over are asked for
				-- again rather than kept for the rest of the session.
				self.covers:retryFailed()
				-- The cache is written over the ticks that follow: finishing a scan has a summary
				-- to show, and encoding and writing every track here is the hitch that follows one.
				self:startSave("scan")
				self.skipped = progress.skipped
				self.errors = progress.errors
				self.summary = {
					tracks = #library.current.tracks,
					albums = #library.current.albums,
					skipped = progress.skipped,
					at = now
				}
				Log.write(
					"info",
					string.format(
						"scan of %s: %d tracks, %d files, %d skipped",
						job.root,
						#library.current.tracks,
						progress.files,
						progress.skipped
					)
				)
			elseif job.error ~= nil then
				self.toasts:show(job.error or "Scan failed", "error")
			else
				self.toasts:show("Scan cancelled", "error")
			end
			job:close()
			self.job = nil
			self.islandOpen = false
			changed = true
			urgent = true
		end
	end

	local addJob = self.addJob
	if addJob ~= nil then
		local library = self.library
		if self:ingest(addJob, nil) then changed = true end

		if addJob:isDone() and not addJob:hasPending() then
			local progress = addJob:progress()
			if progress.phase == "done" then
				---@cast library.current -nil
				library:finish()
				self.covers:retryFailed()
				self.pendingAdd = { tracks = tonumber(progress.tracks) or 0, skipped = progress.skipped or 0 }
				self:startSave("add")
			elseif addJob.error ~= nil then
				self.toasts:show(addJob.error or "Could not add the folder", "error")
			else
				self.toasts:show("Adding the folder was cancelled", "error")
			end
			addJob:close()
			self.addJob = nil
			self.addFolderPath = nil
			changed = true
			urgent = true
		end
	end

	-- The cache write after a finished job, a slice a tick. Nothing on screen moves while it runs;
	-- its completion is what a folder add's page waits for.
	local saving = self.saving
	if saving ~= nil then
		local status, err = saving:step(SAVE_BUDGET)
		if status == "done" then
			self:saveFinished()
			urgent = true
		elseif status == "failed" then
			self:saveFailed(err)
			urgent = true
		end
	end

	-- The summary is a glance, not a report: it goes by itself after a moment.
	if self.summary ~= nil and now - self.summary.at >= 5 then
		self.summary = nil
		changed = true
	end

	if self.job == nil and self.addJob == nil and self.pick == nil and self.saving == nil then
		self.reportedAt = nil
		if self.awaitingAccess == true then return urgent or changed, ACCESS_INTERVAL end
		return urgent or changed, false
	end

	-- A scan wants the display's rate to take what its threads have made; the page behind it is
	-- rebuilt eight times a second instead of sixty. A folder dialog waits for a person and a
	-- cache write waits for the disk, so both leave the tick idle between looks and slices.
	local report = urgent
	if not report and changed then
		local at = self.reportedAt
		report = at == nil or now - at >= SCAN_REBUILD_INTERVAL
	end
	if report then self.reportedAt = now end

	if self.job ~= nil or self.addJob ~= nil then return report, true end
	if self.saving ~= nil then return report, SAVE_TICK end
	return report, PICK_INTERVAL
end

--- The window is going: a cache write still in progress is finished now rather than dropped.
--- The app does not come back to a launch that has to scan the whole folder again for nothing.
function Scan:flush()
	local writer = self.saving
	if writer == nil then return end

	while true do
		local status, err = writer:step(math.huge)
		if status == "done" then
			self:saveFinished()
			return
		elseif status == "failed" then
			self:saveFailed(err)
			return
		end
	end
end

--- The app is being set up again, so nothing will read this job's events any more: tell the
--- inspectors to stop and drop it. Their threads are joined on the next scan -- one of them is in
--- the middle of a file read, and the app is being closed rather than made to wait for it. The
--- dialog's answer file is dropped too, since nobody will poll it.
function Scan:close()
	if self.job ~= nil then
		self.job:cancel()
		self.job = nil
	end
	if self.addJob ~= nil then
		self.addJob:cancel()
		self.addJob = nil
	end
	self:abortSave()
	self.pendingAdd = nil
	Picker.cancel(self.pick)
	self.pick = nil
	self.pickRequest = nil
	self.pickQueue = {}
end

return Scan
