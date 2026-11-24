-- A scan on threads of this process: the folder is walked a slice at a time, split into
-- directory-balanced shards, and handed to four inspector threads that read the files and push
-- tracks back through a channel. The window keeps drawing, playing and searching while the
-- inspectors wait on a slow filesystem, and nothing about the scan is written to disk.
--
-- The walk and the shards stay on this thread, so the folder list and the channel are never read
-- from a thread that does not own them. An inspector gets its shard, the records the library
-- already has for it, and the channel's address as copies made when the thread starts.
local json = require("json")
local threading = require("threading")
local Log = require("beat.log")
local Scanner = require("beat.music.scan")
local artworkCache = require("beat.music.artwork_cache")
local time = require("wonderland.time")

-- Inspectors reading shards at once. Several are what matters on a mount where each read is a
-- round trip, so more in flight is more of the network busy at the same time.
local WORKERS = 4

-- Seconds of folder walking one poll takes. The walk allocates a directory listing per folder, so
-- it is taken in slices of a frame rather than all at once on a large library.
local ENUMERATE_BUDGET = 0.004

-- A directory with thousands of files is split into units; those are rare, and the atomic cover
-- cache write keeps two inspectors safe if they do race for the same album.
local MAX_DIRECTORY_UNIT = 64

-- File entries one poll builds. A large library's manifest is thousands of small tables, and
-- building it all in one tick is a frame's worth of allocation and collection.
local ENTRY_CHUNK = 1024

-- What travels through the library cache is JSON, which only carries UTF-8. lde's `fs` reads
-- Windows names through the ANSI calls, so a name outside ASCII arrives in the system code page
-- ("Antônio" as "Ant\xF4nio") and would make the cache fail to save. Such files are left out and
-- reported until names arrive as UTF-8.
local NOT_UTF8 = "skipped: its name is not UTF-8"

---@param value string
local function sendable(value)
	return (pcall(json.encode, value))
end

--- A name that can be shown, with every byte that kept it from being UTF-8 replaced.
---@overload fun(value: string): string
---@param value string?
local function printable(value)
	if value == nil or sendable(value) then return value end
	return (value:gsub("[\128-\255]", "\239\191\189"))
end

---@param failures { path: string, message: string }[]
---@return { path: string, message: string }[]
local function printableFailures(failures)
	local out = {}
	for at, failure in ipairs(failures) do
		out[at] = { path = printable(failure.path), message = printable(failure.message) }
	end
	return out
end

--- Distribute folders across shards so ordinary albums stay whole and their cover is cached once.
---@param entries beat.ScanEntry[]
---@param count number
local function shard(entries, count)
	---@type table<string, beat.ScanEntry[]>
	local byDir = {}
	---@type string[]
	local dirs = {}

	for _, entry in ipairs(entries) do
		local list = byDir[entry.dir]
		if list == nil then
			list = {}
			byDir[entry.dir] = list
			dirs[#dirs + 1] = entry.dir
		end
		list[#list + 1] = entry
	end

	---@type beat.ScanEntry[][]
	local units = {}
	for _, dir in ipairs(dirs) do
		local list = byDir[dir]
		if #list <= MAX_DIRECTORY_UNIT or count == 1 then
			units[#units + 1] = list
		else
			for at = 1, #list, MAX_DIRECTORY_UNIT do
				---@type beat.ScanEntry[]
				local chunk = {}
				for index = at, math.min(#list, at + MAX_DIRECTORY_UNIT - 1) do
					chunk[#chunk + 1] = list[index]
				end
				units[#units + 1] = chunk
			end
		end
	end

	table.sort(units, |a, b| -> #a > #b)

	---@type beat.ScanEntry[][]
	local shards = {}
	local loads = {}
	for at = 1, count do
		shards[at] = {}
		loads[at] = 0
	end

	for _, unit in ipairs(units) do
		local best = 1
		for at = 2, count do
			if loads[at] < loads[best] then best = at end
		end

		local into = shards[best]
		for _, entry in ipairs(unit) do into[#into + 1] = entry end
		loads[best] += #unit
	end

	return shards
end

---@class beat.ScanInspector
---@field handle threading.Handle
---@field inspected number
---@field tracks number
---@field skipped number
---@field current string?
---@field errors { path: string, message: string }[]
---@field reported boolean # Whether its last message, done or error, has been read
---@field joined boolean # Whether the thread has been joined or handed to the abandoned list
---@field error string?
---@field events threading.Channel # This shard's tracks and messages
---@field control threading.Channel # The channel a cancel is pushed into

--- A cancelled job's threads are joined on a later start rather than holding a frame still. The
--- handles are kept because a `threading.Handle` that is dropped is never joined, and the channels
--- are kept because a thread may not have attached to them yet: letting the last reference go
--- first would leave that thread with an address of freed memory.
---@class beat.AbandonedScan
---@field handles threading.Handle[]
---@field channels threading.Channel[]
---@type beat.AbandonedScan[]
local abandoned = {}

---@param handles threading.Handle[]
---@param channels threading.Channel[]
local function abandon(handles, channels)
	abandoned[#abandoned + 1] = { handles = handles, channels = channels }
end

local function reap()
	for at = #abandoned, 1, -1 do
		local group = abandoned[at]
		local finished = true
		for _, handle in ipairs(group.handles) do
			if not handle:done() then
				finished = false
				break
			end
		end

		if finished then
			for _, handle in ipairs(group.handles) do pcall(handle.join, handle) end
			for _, channel in ipairs(group.channels) do channel:close() end
			table.remove(abandoned, at)
		end
	end
end

local ScanJob = {}
ScanJob.__index = ScanJob

---@class beat.ScanJob
---@field root string
---@field scanner beat.Scanner? # The folder walk, until the walk is done
---@field entrySource beat.Scanner? # The finished walk, while its entries are still being listed
---@field entries beat.ScanEntry[]? # Entries built so far, until they are split into shards
---@field shards beat.ScanEntry[][]? # The shards still to be given an inspector
---@field shardCursor number
---@field workers beat.ScanInspector[]
---@field latest beat.ScanProgress
---@field known table<string, table> # Records from the library, by path
---@field files number # Audio files the walk found
---@field enumSkipped number
---@field enumErrors { path: string, message: string }[]
---@field usedCovers table<string, boolean>
---@field done boolean
---@field error string?
---@field changed boolean

---@param root string
---@return beat.ScanJob
function ScanJob.new(root)
	return setmetatable(
		{
			root = root,
			scanner = nil,
			entrySource = nil,
			entries = nil,
			shards = nil,
			shardCursor = 0,
			workers = {},
			latest = { phase = "enumerate", files = 0, inspected = 0, tracks = 0, skipped = 0, errors = {}, current = nil },
			known = {},
			files = 0,
			enumSkipped = 0,
			enumErrors = {},
			usedCovers = {},
			done = false,
			error = nil,
			changed = false
		},
		ScanJob
	)
end

---@param records table[]? # Records from the library already loaded, for files a scan can skip
---@return table<string, table>
local function knownByPath(records)
	local known = {}
	if records == nil then return known end

	for _, record in ipairs(records) do
		-- A record that cannot travel is left out, and its file is read again: one bad tag must
		-- not stop a scan from starting.
		if type(record) == "table" and type(record.path) == "string" then known[record.path] = record end
	end
	return known
end

--- A scan of `root` on threads of this process. The folder is walked by the polls that follow.
---@param root string
---@param known table[]? # Records from the library already loaded, for files a scan can skip
---@return beat.ScanJob
function ScanJob.start(root, known)
	reap()

	local job = ScanJob.new(root)
	job.known = knownByPath(known)
	job.scanner = Scanner.new(root, { library = false })
	return job
end

--- Takes the next slice of the finished walk's files into entries. When the last slice is in,
--- the entries are split into shards; each poll starts one inspector from there.
---@param self beat.ScanJob
function ScanJob:takeEntryChunk()
	local source = self.entrySource
	---@cast source -nil
	local entries = self.entries
	---@cast entries -nil

	local taken = source:takeEntries(ENTRY_CHUNK)
	for _, entry in ipairs(taken) do
		if sendable(entry.path) then
			entries[#entries + 1] = entry
		else
			self.enumSkipped += 1
			self.enumErrors[#self.enumErrors + 1] = { path = printable(entry.path), message = NOT_UTF8 }
		end
	end

	if #taken == ENTRY_CHUNK then return end

	self.entrySource = nil
	self.entries = nil
	self.files = #entries
	self.latest.files = self.files
	self.latest.skipped = self.enumSkipped

	if self.files == 0 then
		self.done = true
		self.latest.phase = "done"
		self.latest.errors = self.enumErrors
		return
	end

	-- The shards are handed out one per poll: starting four threads and copying four shards in
	-- one tick is a frame's worth of work on a large library, and a scan start should not drop one.
	self.shards = shard(entries, math.min(WORKERS, self.files))
	self.shardCursor = 0
end

--- Starts the next shard's inspector, if one is left. One per poll keeps the thread starts and
--- their tables spread across frames.
---@param self beat.ScanJob
function ScanJob:startNextInspector()
	local shards = self.shards
	if shards == nil then return end

	local root, known = self.root, self.known
	while self.shardCursor < #shards do
		self.shardCursor += 1
		local shardEntries = shards[self.shardCursor]
		if #shardEntries > 0 then
			local shardKnown = {}
			for _, entry in ipairs(shardEntries) do
				local record = known[entry.path]
				if record ~= nil then shardKnown[entry.path] = record end
			end

			-- Every inspector has a channel of its own: a channel closes for every state holding
			-- it, so the first shard to finish would stop the others if they shared one.
			local events = threading.channel()
			local control = threading.channel()
			local eventsAddress, controlAddress = events:address(), control:address()
			local workerIndex = #self.workers + 1
			local ok, handle = pcall(threading.spawn, function()
				require("beat.app.services.scan.inspect").run(
					shardEntries,
					shardKnown,
					root,
					eventsAddress,
					controlAddress,
					workerIndex
				)
			end)
			if not ok then
				-- An inspector that cannot start is the end of the scan: the others would fill a
				-- library this job is about to say it failed. They are told to stop the same way a
				-- cancel tells them, and their channels stay alive until their threads have ended.
				events:close()
				control:close()
				local handles = {}
				local channels = {}
				for _, worker in ipairs(self.workers) do
					worker.joined = true
					handles[#handles + 1] = worker.handle
					channels[#channels + 1] = worker.events
					channels[#channels + 1] = worker.control
					worker.control:push(true)
				end
				abandon(handles, channels)
				self.workers = {}
				self.shards = nil
				self.done = true
				self.error = "could not start the scan: " .. tostring(handle)
				self.latest.current = nil
				Log.write("error", self.error)
				return
			end

			self.workers[workerIndex] = {
				handle = handle --[[@as threading.Handle]],
				events = events,
				control = control,
				inspected = 0,
				tracks = 0,
				skipped = 0,
				current = nil,
				errors = {},
				reported = false,
				joined = false,
				error = nil
			}
			return
		end
	end

	self.shards = nil
end

--- Copies the running totals into the progress table the view draws, answering whether anything
--- moved since the last poll.
---@param self beat.ScanJob
---@return boolean changed
function ScanJob:updateProgress()
	local latest = self.latest
	local phase, files, inspected, tracks, skipped, current

	local scanner = self.scanner
	if scanner ~= nil then
		phase = "enumerate"
		files = #scanner.files
		inspected = 0
		tracks = 0
		skipped = scanner.skipped
		current = scanner.current
	else
		phase = "inspect"
		files = self.files
		inspected = 0
		tracks = 0
		skipped = self.enumSkipped
		current = nil
		for _, worker in ipairs(self.workers) do
			inspected += worker.inspected
			tracks += worker.tracks
			skipped += worker.skipped
			current = worker.current or current
		end
	end

	if latest.phase == phase
		and latest.files == files
		and latest.inspected == inspected
		and latest.tracks == tracks
		and latest.skipped == skipped
		and latest.current == current then
		return false
	end

	latest.phase = phase
	latest.files = files
	latest.inspected = inspected
	latest.tracks = tracks
	latest.skipped = skipped
	latest.current = current
	return true
end

--- Whether the scan has ended: every inspector reported and was joined, and its channel is empty.
--- A scan that failed keeps its phase in progress, so the service shows the job's error instead of
--- saving what the scan did manage to read.
---@param self beat.ScanJob
---@return boolean finished
function ScanJob:checkFinished()
	if self.done or self.scanner ~= nil or self.entrySource ~= nil or self.shards ~= nil then return false end

	for _, worker in ipairs(self.workers) do
		if worker.events:count() > 0 or not worker.joined then return false end
	end

	-- `walk` reports before it returns, so a thread that ended without a message raised outside
	-- its own pcall. That is a failure of the scan rather than a shard that finished quietly.
	for _, worker in ipairs(self.workers) do
		if not worker.reported and worker.error == nil then
			worker.error = "the scan inspector ended without finishing"
		end
	end

	local fatal = nil
	for _, worker in ipairs(self.workers) do
		fatal = fatal or worker.error
	end

	if fatal ~= nil then
		self.done = true
		self.error = fatal
		self.latest.current = nil
		return true
	end

	local errors = {}
	for _, failure in ipairs(self.enumErrors) do errors[#errors + 1] = failure end
	local inspected, tracks, skipped = 0, 0, self.enumSkipped
	for _, worker in ipairs(self.workers) do
		inspected += worker.inspected
		tracks += worker.tracks
		skipped += worker.skipped
		for _, failure in ipairs(worker.errors) do errors[#errors + 1] = failure end
	end

	self.done = true
	self.latest.phase = "done"
	self.latest.inspected = inspected
	self.latest.tracks = tracks
	self.latest.skipped = skipped
	self.latest.errors = errors
	artworkCache.prune(self.root, self.usedCovers)
	return true
end

--- The tracks and progress the app has not seen yet. At most `limit` messages are taken in one
--- tick, so a fast local scan cannot make a single frame add thousands of rows.
---@param limit number?
---@param self beat.ScanJob
---@return table[] events
---@return boolean changed
function ScanJob:poll(limit)
	limit = limit or 32

	if self.done then
		self.changed = false
		return {}, false
	end

	local changed = self.changed
	self.changed = false

	local scanner = self.scanner
	if scanner ~= nil then
		scanner:enumerateStep(ENUMERATE_BUDGET, time.now)
		if scanner.phase ~= "enumerate" then
			self.scanner = nil
			self.entrySource = scanner
			self.entries = {}
			self.enumSkipped = scanner.skipped
			self.enumErrors = printableFailures(scanner.errors)
			self.files = #scanner.files
			self.latest.phase = "inspect"
			self.latest.files = self.files
			self.latest.inspected = 0
			self.latest.tracks = 0
			self.latest.skipped = self.enumSkipped
			self.latest.current = nil
			changed = true
		end
	end

	if self.entrySource ~= nil then
		self:takeEntryChunk()
		changed = true
	end

	if self.shards ~= nil then
		-- One a tick: a rescan copies a shard's known records to its thread here, and two of those
		-- in one tick is work the frame budget does not have.
		self:startNextInspector()
		changed = true
	end

	local events = {}
	local budget = limit
	for _, worker in ipairs(self.workers) do
		local channel = worker.events
		while budget > 0 do
			local message = channel:pop()
			if message == nil then break end
			budget -= 1

			if type(message) == "table" then
				local kind = message.type
				if kind == "track" or kind == "reused" then
					events[#events + 1] = message
				elseif kind == "progress" then
					worker.inspected = message.inspected or worker.inspected
					worker.tracks = message.tracks or worker.tracks
					worker.skipped = message.skipped or worker.skipped
					worker.current = message.current
				elseif kind == "done" then
					if not worker.reported then
						worker.reported = true
						worker.inspected = message.inspected or worker.inspected
						worker.tracks = message.tracks or worker.tracks
						worker.skipped = message.skipped or worker.skipped
						worker.errors = message.errors or worker.errors
						worker.current = nil
						for _, cover in ipairs(message.covers or {}) do
							self.usedCovers[cover] = true
						end
					end
				elseif kind == "error" then
					if worker.error == nil then
						worker.error = message.message or "the scan inspector failed"
					end
				end
			end
		end

		if budget <= 0 then break end
	end

	-- A thread that has ended is joined once, to give its state's memory back. Its last message
	-- may still be in the channel, so it is judged by `checkFinished`, not here.
	for _, worker in ipairs(self.workers) do
		if not worker.joined and worker.handle:done() then
			worker.joined = true
			local ok, err = pcall(worker.handle.join, worker.handle)
			if not ok and worker.error == nil then worker.error = tostring(err) end
		end
	end

	if #events > 0 then changed = true end
	if not self.done then
		if self:updateProgress() then changed = true end
		if self:checkFinished() then changed = true end
	end

	return events, changed
end

---@param self beat.ScanJob
---@return beat.ScanProgress
function ScanJob:progress()
	return self.latest
end

---@param self beat.ScanJob
---@return boolean
function ScanJob:isDone()
	return self.done
end

---@param self beat.ScanJob
---@return boolean
function ScanJob:hasPending()
	for _, worker in ipairs(self.workers) do
		if worker.events:count() > 0 then return true end
	end
	return false
end

--- Asks the inspectors to stop: each is sent a message on its own control channel and stops after
--- the file it is reading. The threads and their channels are kept until they can be joined on a
--- later start, since one of them is in the middle of a read and might not have attached yet.
---@param self beat.ScanJob
---@return boolean
function ScanJob:cancel()
	if self.done then return true end

	self.done = true
	self.changed = true
	if self.scanner ~= nil then self.scanner:cancel() end
	self.scanner = nil
	self.entrySource = nil
	self.entries = nil
	self.shards = nil

	local handles = {}
	local channels = {}
	for _, worker in ipairs(self.workers) do
		if not worker.joined then
			worker.joined = true
			handles[#handles + 1] = worker.handle
			channels[#channels + 1] = worker.events
			channels[#channels + 1] = worker.control
			worker.control:push(true)
		end
	end
	if #handles > 0 then abandon(handles, channels) end
	self.workers = {}

	return true
end

---@param self beat.ScanJob
function ScanJob:close()
	for _, worker in ipairs(self.workers) do
		if not worker.joined then
			worker.joined = true
			pcall(worker.handle.join, worker.handle)
		end
		worker.events:close()
		worker.control:close()
	end
	self.workers = {}
	self.scanner = nil
	self.entrySource = nil
	self.entries = nil
	self.shards = nil
end

return ScanJob
