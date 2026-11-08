-- Reading a folder into the library: where the library comes from, the worker that walks it, and
-- the two cards over the corner that say how far it has got. The scan is the only thing that makes
-- a library appear, so it also owns the folder the library was chosen from and the question the
-- first launch asks -- everything a view needs to say "no folder yet" comes from here.
local Picker = require("beat.app.services.scan.picker")
local ScanJob = require("beat.app.services.scan.job")

---@class beat.ScanSummary
---@field tracks number
---@field albums number
---@field skipped number
---@field at number

---@class beat.ScanService: beat.Service
---@field job beat.ScanJob? # The worker reading the folder, while there is one
---@field pick beat.FolderPick? # The system folder dialog, while it is open
---@field islandOpen boolean # Whether the reading island was left showing
---@field summary beat.ScanSummary? # What the last finished scan added, until it is dismissed
---@field skipped number # Files the last finished scan could not read
---@field errors { path: string, message: string }[]
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
Scan.handles = {
	"startScan", "rescan", "chooseFolder", "cancelScan",
	"hideScanIsland", "showScanIsland", "dismissScanSummary",
}

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
	return setmetatable({
		job = nil,
		pick = nil,
		islandOpen = true,
		summary = nil,
		skipped = 0,
		errors = {},
		settings = deps.settings,
		library = deps.library,
		covers = deps.covers,
		playback = deps.playback,
		toasts = deps.toasts,
		emit = deps.emit,
		window = deps.window,
		options = deps.options or {},
	}, Scan)
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
--- chance to draw.
function Scan:resume()
	local root = self.settings.values.root
	if root == nil or self.options.scan == false then return end
	if self.library.current == nil then self:start(root) end
end

--- A new library for a root. What was playing is from the old one, so it stops; every cover on
--- screen belongs to an album that is gone, so they are released. The app goes home with the
--- history forgotten, because every page behind the scan showed the library it replaced.
---@param root string
function Scan:start(root)
	Picker.cancel(self.pick)
	self.pick = nil
	if self.job ~= nil then self.job:cancel() end

	self.playback:reset()
	self.covers:releaseAll()
	self.library:replace(root)
	self.job = ScanJob.start(root)
	self.islandOpen = true
	self.summary = nil
	self.skipped = 0
	self.errors = {}

	self.settings.values.root = root
	self.settings:save()

	self:emit({ type = "reset", page = { kind = "home"}})
end

function Scan:update(message)
	local kind = message.type
	if kind == "startScan" then
		self:start(message.root)
	elseif kind == "rescan" then
		local root = self.settings.values.root
		if root ~= nil then self:start(root) end
	elseif kind == "chooseFolder" then
		if self.pick == nil then self.pick = Picker.start(self.window()) end
	elseif kind == "cancelScan" then
		if self.job ~= nil then
			self.job:cancel()
			self.job = nil
			self.islandOpen = false
			self.toasts:show("Scan cancelled")
		end
	elseif kind == "hideScanIsland" then
		self.islandOpen = false
	elseif kind == "showScanIsland" then
		self.islandOpen = true
	elseif kind == "dismissScanSummary" then
		self.summary = nil
	end
end

--- The dialog is modal, so its answer is read back from a file; the tracks arrive the same way,
--- a chunk a tick, so a fast local scan cannot make one frame add thousands of rows.
function Scan:step(now)
	local changed = false

	if self.pick ~= nil then
		local chosen, status = Picker.poll(self.pick)
		if chosen ~= nil then
			self.pick = nil
			self:start(chosen)
			changed = true
		elseif status ~= nil then
			self.pick = nil
			if status == "no-picker" then
				self.toasts:show("No system folder dialog is available on this machine", "error")
			end
			changed = true
		end
	end

	local job = self.job
	if job ~= nil then
		local library = self.library
		local events, progressed = job:poll(32)
		if progressed then changed = true end
		for _, event in ipairs(events) do
			---@cast event table
			if event.type == "track" and library.current ~= nil then
				local track, gainedCover
				-- One unreadable file must not stop the scan: it is a toast and a line in the
				-- settings screen's list, not the end of the folder.
				local ok, err = pcall(function()
					track, gainedCover = library:add(event.info, event.entry, event.cover,
					event.coverCache)
				end)
				if not ok then
					self.toasts:show("Could not read a scanned track", "error")
					self.errors[#self.errors + 1] = { path = event.entry.path, message = tostring(err)}
				elseif track ~= nil and (track.hasPicture or gainedCover) then
					self.covers:forget(track.albumId)
				end
				changed = true
			end
		end

		if job:isDone() and not job:hasPending() then
			local progress = job:progress()
			if progress.phase == "done" then
				---@cast library.current -nil
				library:finish()
				library:save()
				self.skipped = progress.skipped
				self.errors = progress.errors
				self.summary = {
					tracks = #library.current.tracks,
					albums = #library.current.albums,
					skipped = progress.skipped,
					at = now,
				}
			elseif job.error ~= nil then
				self.toasts:show(job.error or "Scan failed", "error")
			else
				self.toasts:show("Scan cancelled", "error")
			end
			job:close()
			self.job = nil
			self.islandOpen = false
			changed = true
		end
	end

	-- The summary is a glance, not a report: it goes by itself after a moment.
	if self.summary ~= nil and now - self.summary.at >= 5 then
		self.summary = nil
		changed = true
	end

	return changed, self.job ~= nil or self.pick ~= nil
end

--- The app is being set up again, so nothing will read this job's events any more: tell the
--- worker to stop and drop it. Its temporary files are left to the temp directory rather than
--- deleted under a worker that may still be reading them. The dialog's answer file is dropped
--- too, since nobody will poll it.
function Scan:close()
	if self.job ~= nil then
		self.job:cancel()
		self.job = nil
	end
	Picker.cancel(self.pick)
	self.pick = nil
end

return Scan
