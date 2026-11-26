-- Writing tags into the files of the library. A file is rewritten whole, which on a network mount
-- is a download and an upload, so the writing happens on a worker thread, one file at a time, as
-- a task in the top bar. Each file is read again on the same thread once it is written, and the
-- track takes its new place in the library straight away: a rescan of the folder would read every
-- other file in it too, and a library kept in one folder would be read whole for one title.
local path = require("path")
local threading = require("threading")

---@class beat.MetadataJob
---@field trackId number
---@field changes treble.TagChanges

---@class beat.MetadataService: beat.ServiceInstance
---@field library beat.LibraryService
---@field playback beat.PlaybackService
---@field tasks beat.TasksService
---@field jobs beat.MetadataJob[]
---@field nextJob number
---@field pool threading.Pool?
---@field handle threading.PoolHandle?
---@field running beat.MetadataJob?
---@field task beat.Task?
---@field written number
---@field failures string[]
local Metadata = {}
Metadata.__index = Metadata
Metadata.needs = { "library", "playback", "tasks" }

--- Runs on the worker: writes the tags, then reads the file back the way a scan does.
---@param file string
---@param changes treble.TagChanges
---@return boolean ok
---@return table|string infoOrErr
---@return number? modified
local function writeFile(file, changes)
	local audio = require("treble.audio")
	local fs = require("fs")
	local ok, err = audio.writeTags(file, changes)
	if not ok then return false, tostring(err) end
	local info, inspectErr = audio.inspect(file)
	if info == nil then return false, tostring(inspectErr) end
	local stat = fs.stat(file)
	return true, info, stat?.modifyTime
end

---@param deps { library: beat.LibraryService, playback: beat.PlaybackService, tasks: beat.TasksService }
---@return beat.MetadataService
function Metadata.new(deps)
	return setmetatable({
		library = deps.library,
		playback = deps.playback,
		tasks = deps.tasks,
		jobs = {},
		nextJob = 1,
		pool = nil,
		handle = nil,
		running = nil,
		task = nil,
		written = 0,
		failures = {}
	}, Metadata)
end

--- The queue holds track tables rather than ids, so a track read again is put in the old one's
--- place there; what is playing keeps playing and shows its new title.
---@param self beat.MetadataService
---@param old beat.Track
---@param new beat.Track
local function swapQueued(self, old, new)
	local queue = self.playback.player.queue
	if queue == nil then return end
	local tracks = queue.tracks
	for at = 1, #tracks do
		if tracks[at] == old then tracks[at] = new end
	end
end

---@param self beat.MetadataService
---@param id number
---@return beat.Track?
local function trackOf(self, id)
	local current = self.library.current
	if current == nil then return nil end
	return current:track(id)
end

---@param self beat.MetadataService
---@param job beat.MetadataJob
---@param info table
---@param modified number?
local function apply(self, job, info, modified)
	local library = self.library
	local old = trackOf(self, job.trackId)
	if old == nil then return end
	local file = old.path
	library:forgetFolder(file)
	local name = path.basename(file)
	local entry = {
		path = file,
		dir = path.dirname(file),
		name = name,
		ext = (name:match("%.([^%.]+)$") or ""):lower(),
		modifyTime = modified
	}
	local track = library:add(info --[[@as treble.audio.Inspect]], entry, old.coverPath, old.coverCache)
	if track ~= nil then swapQueued(self, old, track) end
end

---@param self beat.MetadataService
local function finishAll(self)
	local library = self.library
	if self.written > 0 and library.current ~= nil then
		library:finish()
		library.current:forgetSearch()
		library:save()
	end
	local task = assert(self.task)
	local failed = #self.failures
	if failed == 0 then
		task:finish(self.written == 1 and "1 file updated" or (self.written .. " files updated"))
	else
		task:fail(failed .. (failed == 1 and " file" or " files") .. " could not be written: " .. self.failures[1])
	end
	self.task = nil
	self.jobs = {}
	self.nextJob = 1
	self.written = 0
	self.failures = {}
end

---@param self beat.MetadataService
local function startNext(self)
	local job = self.jobs[self.nextJob]
	if job == nil then
		finishAll(self)
		return
	end
	local track = trackOf(self, job.trackId)
	if track == nil then
		self.nextJob = self.nextJob + 1
		self.failures[#self.failures + 1] = "a track left the library"
		return startNext(self)
	end
	local pool = self.pool
	if pool == nil then
		pool = threading.pool(1, writeFile)
		self.pool = pool
	end
	self.running = job
	self.handle = pool:run(track.path, job.changes)
	local total = #self.jobs
	assert(self.task):update({ detail = track.title, progress = (self.nextJob - 1) / total })
end

---@param now number
---@return boolean? changed
---@return boolean|number? busy
function Metadata:step(now)
	local handle = self.handle
	if handle == nil then return nil end
	if not handle:done() then return nil, 0.25 end

	local job = assert(self.running)
	self.handle = nil
	self.running = nil
	local joined, ok, infoOrErr, modified = pcall(handle.join, handle)
	if not joined then
		self.failures[#self.failures + 1] = tostring(ok)
	elseif not ok then
		self.failures[#self.failures + 1] = tostring(infoOrErr)
	else
		apply(self, job, infoOrErr --[[@as table]], modified --[[@as number?]])
		self.written = self.written + 1
	end
	self.nextJob = self.nextJob + 1
	startNext(self)
	return true, self.handle ~= nil and 0.25 or false
end

function Metadata:close()
	if self.handle ~= nil then pcall(self.handle.join, self.handle) end
	self.handle = nil
	if self.pool ~= nil then self.pool:close() end
	self.pool = nil
end

Metadata.on = {
	--- Tags to write into some tracks' files. Jobs sent while others are being written join them.
	---@param self beat.MetadataService
	---@param message beat.WriteMetadataMessage
	writeMetadata = function(self, message)
		if type(message.trackIds) ~= "table" or type(message.changes) ~= "table" or next(message.changes) == nil then return end
		for _, id in ipairs(message.trackIds) do
			self.jobs[#self.jobs + 1] = { trackId = id, changes = message.changes }
		end
		if self.task == nil then
			self.task = self.tasks:start({ title = "Writing tags", progress = 0 })
		end
		if self.handle == nil then startNext(self) end
	end
}

return Metadata
