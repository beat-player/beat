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

---@class beat.ScanService
---@field job beat.ScanJob? # The worker reading the folder, while there is one
---@field addJob beat.ScanJob? # The worker reading one folder into the existing library, while there is one
---@field addFolder string? # The folder that worker is reading
---@field pick beat.FolderPick? # The system folder dialog, while it is open
---@field pickRequest { reply: string? }? # Who the open dialog's answer goes to; nil reply is a library root
---@field pickQueue { reply: string? }[] # Dialogs asked for while one was open
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
	"startScan", "rescan", "chooseFolder", "pickFolder", "libraryAddFolder", "cancelScan",
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
		addJob = nil,
		addFolder = nil,
		pick = nil,
		pickRequest = nil,
		pickQueue = {},
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

	self.emit({ type = "reset", page = { kind = "home"}})
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
	self.addFolder = folder
	self.addJob = ScanJob.start(folder)
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
			errors[#errors + 1] = { path = event.entry.path, message = tostring(err)}
		end
	elseif track ~= nil and (track.hasPicture or gainedCover) then
		self.covers:forget(track.albumId)
	end
end

function Scan:update(message)
	local kind = message.type
	if kind == "startScan" then
		self:start(message.root)
	elseif kind == "rescan" then
		local root = self.settings.values.root
		if root ~= nil then self:start(root) end
	elseif kind == "chooseFolder" then
		self:startPick({})
	elseif kind == "pickFolder" then
		if type(message.reply) ~= "string" or message.reply == "" then
			self.toasts:show("A folder pick needs a reply message type", "error")
		else
			self:startPick({ reply = message.reply })
		end
	elseif kind == "libraryAddFolder" then
		if type(message.path) ~= "string" or message.path == "" then
			self.toasts:show("Adding a folder needs a path", "error")
		else
			self:addFolder(message.path)
		end
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
			local request = self.pickRequest
			self.pick = nil
			self.pickRequest = nil
			if request ~= nil and request.reply ~= nil then
				self.emit({ type = request.reply, path = chosen})
			else
				self:start(chosen)
			end
			self:nextPick()
			changed = true
		elseif status ~= nil then
			local request = self.pickRequest
			self.pick = nil
			self.pickRequest = nil
			if status == "no-picker" then
				self.toasts:show("No system folder dialog is available on this machine", "error")
			end
			if request ~= nil and request.reply ~= nil then
				self.emit({ type = request.reply, path = nil})
			end
			self:nextPick()
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
				self:addTrack(event, self.errors)
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

	local addJob = self.addJob
	if addJob ~= nil then
		local library = self.library
		local events, progressed = addJob:poll(32)
		if progressed then changed = true end
		for _, event in ipairs(events) do
			---@cast event table
			if event.type == "track" and library.current ~= nil then
				self:addTrack(event, nil)
				changed = true
			end
		end

		if addJob:isDone() and not addJob:hasPending() then
			local progress = addJob:progress()
			if progress.phase == "done" then
				---@cast library.current -nil
				library:finish()
				local saved, saveErr = library:save()
				if not saved then self.toasts:show(saveErr or "Could not save the library", "error") end
				self.emit({ type = "libraryChanged"})
				local tracks = tonumber(progress.tracks) or 0
				self.toasts:show("Added " .. tracks .. " track" .. (tracks == 1 and "" or "s")
					.. " to the library")
				if (progress.skipped or 0) > 0 then
					self.toasts:show(progress.skipped .. " files could not be read", "error")
				end
			elseif addJob.error ~= nil then
				self.toasts:show(addJob.error or "Could not add the folder", "error")
			else
				self.toasts:show("Adding the folder was cancelled", "error")
			end
			addJob:close()
			self.addJob = nil
			self.addFolder = nil
			changed = true
		end
	end

	-- The summary is a glance, not a report: it goes by itself after a moment.
	if self.summary ~= nil and now - self.summary.at >= 5 then
		self.summary = nil
		changed = true
	end

	return changed, self.job ~= nil or self.addJob ~= nil or self.pick ~= nil
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
	if self.addJob ~= nil then
		self.addJob:cancel()
		self.addJob = nil
	end
	Picker.cancel(self.pick)
	self.pick = nil
	self.pickRequest = nil
	self.pickQueue = {}
end

return Scan
