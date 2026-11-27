-- A scan on threads of this process: the folder is walked on a thread of its own and sent back a
-- batch of entries at a time, split into directory-balanced shards, and handed to four inspector
-- threads that read the files and push tracks back through channels. The window keeps drawing,
-- playing and searching while a slow filesystem is read, and nothing about the scan is written to
-- disk.
--
-- The app's thread owns the manifest and the shards: the walk thread sends entries through a
-- channel and waits when the app is behind, so neither table is read from a thread that does not
-- own it. An inspector gets its shard, the records the library already has for it, and the
-- channel's address as copies made when the thread starts.
local json = require("json")
local threading = require("threading")
local Log = require("beat.log")
local Scanner = require("beat.music.scan")
local artworkCache = require("beat.music.artwork_cache")
local time = require("wonderland.time")

-- Inspectors reading shards at once. Several are what matters on a mount where each read is a
-- round trip, so more in flight is more of the network busy at the same time.
local WORKERS = 4

-- Seconds one slice of the folder walk spends reading directory metadata before the walk thread
-- looks for a cancel. The walk itself runs on a thread of its own: on a large library or a network
-- mount a directory listing per folder is more than a frame may hold.
local WALK_SLICE = 0.02

-- How many entry batches the walk may queue ahead of the app before it waits. The app takes one
-- a tick, and a batch is the copy the old main-thread walk made each tick; letting the walk rush
-- far ahead would keep a second copy of a large manifest in the channel.
local WALK_BACKLOG = 3

-- Seconds between progress messages while the walk runs: enough for the card's count to move, far
-- fewer than a message a frame.
local WALK_PROGRESS = 0.2

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

--- Whether an entry path can travel through the library cache. A path with no byte outside ASCII
--- is always JSON-safe; only one with high bytes needs the encode check. Most paths are ASCII, so
--- this keeps the per-entry test a byte scan rather than an encode.
---@param value string
---@return boolean
local function sendablePath(value)
	if value:find("[\128-\255]") == nil then return true end
	return sendable(value)
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
---@field walker threading.Handle? # The thread walking the folder, until it has finished
---@field walkEvents threading.Channel? # Entry batches and progress from the walk
---@field walkControl threading.Channel? # A cancel for the walk
---@field walkDone boolean # Whether the walk has handed over its last entry
---@field walkReported boolean # Whether the walk's final message has been read
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
			walker = nil,
			walkEvents = nil,
			walkControl = nil,
			walkDone = false,
			walkReported = false,
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

--- A scan of `root` on threads of this process. The folder walk and the file inspections run on
--- threads of their own; the polls that follow take what they send a batch at a time.
---@param root string
---@param known table[]? # Records from the library already loaded, for files a scan can skip
---@return beat.ScanJob
function ScanJob.start(root, known)
	reap()

	local job = ScanJob.new(root)
	job.known = knownByPath(known)
	job:startWalk()
	return job
end

--- The folder walk, on a thread of its own: `readdir` and the per-folder bookkeeping happen
--- there, and the app is sent an entry batch at a time. A cancelled walk is a `true` on the
--- control channel: it stops at the next directory boundary, closes the folder it is reading and
--- says nothing more.
---@param root string
---@param eventsAddress string
---@param controlAddress string
function ScanJob.walk(root, eventsAddress, controlAddress)
	local threading = require("threading")
	local events = threading.channelFromAddress(eventsAddress)
	local control = threading.channelFromAddress(controlAddress)
	local scanner = Scanner.new(root, { library = false })
	local clock = time.now

	---@return boolean cancelled
	local function cancelled()
		if control:count() == 0 then return false end
		control:pop()
		scanner:cancel()
		return true
	end

	--- A batch into the app's manifest. The cache's UTF-8 check stays on the app's thread: this is
	--- still the walk thread, and the main state's json is the one that says what can travel.
	local function pushEntries()
		local batch = scanner:takeEntries(ENTRY_CHUNK)
		if #batch > 0 then events:push({ type = "entries", entries = batch }) end
	end

	--- Waits for the app to catch up when too many batches are queued, answering true when the
	--- visit is a cancel.
	---@return boolean cancelled
	local function waitForRoom()
		while events:count() >= WALK_BACKLOG do
			if cancelled() then return true end
			threading.sleep(2)
		end
		return false
	end

	local lastProgress = clock()
	while scanner.phase == "enumerate" do
		scanner:enumerateStep(WALK_SLICE, clock)
		if cancelled() then return end

		local now = clock()
		if now - lastProgress >= WALK_PROGRESS then
			lastProgress = now
			events:push({
				type = "progress",
				files = #scanner.files,
				skipped = scanner.skipped,
				current = scanner.current
			})
		end

		if #scanner.files - scanner.entryIndex + 1 >= ENTRY_CHUNK then
			if waitForRoom() then return end
			pushEntries()
		end
	end

	-- The last, partial batches, then the counts and failures the inspectors start from.
	while scanner.entryIndex <= #scanner.files do
		if waitForRoom() then return end
		pushEntries()
	end

	local found = scanner.errors
	events:push({
		type = "done",
		skipped = scanner.skipped,
		errors = found
	})
end

--- Starts the walk thread. A walk that cannot start fails the scan the way an inspector that
--- cannot start does, rather than leaving a job that waits forever for entries.
---@param self beat.ScanJob
function ScanJob:startWalk()
	local events = threading.channel()
	local control = threading.channel()
	local root = self.root
	local eventsAddress, controlAddress = events:address(), control:address()
	local ok, handle = pcall(threading.spawn, function()
		require("beat.app.services.scan.job").walk(root, eventsAddress, controlAddress)
	end)
	if not ok then
		events:close()
		control:close()
		self.done = true
		self.error = "could not start the scan: " .. tostring(handle)
		self.latest.current = nil
		Log.write("error", self.error)
		return
	end

	self.walker = handle
	self.walkEvents = events
	self.walkControl = control
	self.entries = {}
	self.walkDone = false
	self.walkReported = false
end

--- Takes what the walk has sent: entry batches into the manifest, progress into the card, and the
--- last message into the shards. One entry batch a poll is the bound the old main-thread walk had;
--- progress and the final message are small and are taken whenever they come.
---@param self beat.ScanJob
---@return boolean changed
function ScanJob:pollWalk()
	local channel = self.walkEvents
	if channel == nil then return false end

	local changed = false
	while true do
		local message = channel:pop()
		if message == nil then break end

		local kind = message.type
		if kind == "entries" then
			local entries = self.entries
			---@cast entries -nil
			local batch = message.entries
			for at = 1, #batch do
				local entry = batch[at]
				if sendablePath(entry.path) then
					entries[#entries + 1] = entry
				else
					self.enumSkipped += 1
					self.enumErrors[#self.enumErrors + 1] = { path = printable(entry.path), message = NOT_UTF8 }
				end
			end
			changed = true
			break
		elseif kind == "progress" then
			local latest = self.latest
			local files, skipped, current = message.files, message.skipped, message.current
			if latest.files ~= files or latest.skipped ~= skipped or latest.current ~= current then
				latest.phase = "enumerate"
				latest.files = files or latest.files
				latest.skipped = skipped or latest.skipped
				latest.current = current
				changed = true
			end
		elseif kind == "done" then
			self.walkDone = true
			self.walkReported = true
			self.enumSkipped += message.skipped or 0
			local found = message.errors
			if found ~= nil then
				local printableErrors = printableFailures(found)
				for at = 1, #printableErrors do self.enumErrors[#self.enumErrors + 1] = printableErrors[at] end
			end

			local entries = self.entries or {}
			self.entries = nil
			self.files = #entries
			self.latest.phase = "inspect"
			self.latest.files = self.files
			self.latest.inspected = 0
			self.latest.tracks = 0
			self.latest.skipped = self.enumSkipped
			self.latest.current = nil

			if self.files == 0 then
				self.done = true
				self.latest.phase = "done"
				self.latest.errors = self.enumErrors
			else
				-- The shards are handed out one per poll: starting four threads and copying four
				-- shards in one tick is a frame's worth of work on a large library.
				self.shards = shard(entries, math.min(WORKERS, self.files))
				self.shardCursor = 0
			end
			changed = true
			break
		end
	end

	-- A walk thread that ended without its final message raised outside its own pcall: that is a
	-- failure of the scan, not a walk still going, and waiting for entries that will never come
	-- would leave the job running forever.
	if not self.walkReported then
		local walker = self.walker
		if walker ~= nil and channel:count() == 0 and walker:done() then
			self.walkReported = true
			self.done = true
			self.error = "the scan walk ended without finishing"
			self.latest.current = nil
			changed = true
		end
	end

	return changed
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
	-- While the walk runs its own messages are the progress: `pollWalk` writes the count and the
	-- folder it is reading into `latest` as they arrive.
	if not self.walkDone then return false end

	local latest = self.latest
	local phase = "inspect"
	local files = self.files
	local inspected, tracks, skipped, current = 0, 0, self.enumSkipped, nil
	for _, worker in ipairs(self.workers) do
		inspected += worker.inspected
		tracks += worker.tracks
		skipped += worker.skipped
		current = worker.current or current
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
	if self.done or not self.walkReported or self.shards ~= nil then return false end

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
	-- A completed scan's covers are pruned off the main thread: the scan's last tick has a
	-- library to finish and a cache to save, and a readdir plus a delete per stale cover is not
	-- work for a frame. A cancelled or failed scan never gets here.
	artworkCache.pruneAsync(self.root, self.usedCovers)
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

	-- One a tick: a rescan copies a shard's known records to its thread here, and two of those in
	-- one tick is work the frame budget does not have. This runs before the walk is polled so the
	-- tick that takes the walk's last message only builds the shards; the first inspector's copy
	-- and thread start wait for the next tick.
	if self.shards ~= nil then
		self:startNextInspector()
		changed = true
	end

	if not self.walkDone then
		if self:pollWalk() then changed = true end
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
	local walkEvents = self.walkEvents
	if walkEvents ~= nil and walkEvents:count() > 0 then return true end
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
	self.entries = nil
	self.shards = nil

	local handles = {}
	local channels = {}
	if self.walker ~= nil then
		handles[#handles + 1] = self.walker
		channels[#channels + 1] = self.walkEvents
		channels[#channels + 1] = self.walkControl
		self.walkControl:push(true)
		self.walker, self.walkEvents, self.walkControl = nil, nil, nil
	end
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
	if self.walker ~= nil then
		pcall(self.walker.join, self.walker)
		self.walker = nil
	end
	if self.walkEvents ~= nil then
		self.walkEvents:close()
		self.walkEvents = nil
	end
	if self.walkControl ~= nil then
		self.walkControl:close()
		self.walkControl = nil
	end
	for _, worker in ipairs(self.workers) do
		if not worker.joined then
			worker.joined = true
			pcall(worker.handle.join, worker.handle)
		end
		worker.events:close()
		worker.control:close()
	end
	self.workers = {}
	self.entries = nil
	self.shards = nil
end

return ScanJob
