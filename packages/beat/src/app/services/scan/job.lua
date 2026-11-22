-- A scan in a process of its own, or on a thread where there is no second process to start.
--
-- The worker walks the folder and writes one JSON line per inspected track; this side reads what
-- has arrived since the last tick and hands the app the tracks. The window keeps drawing, playing
-- and searching while the worker waits on a slow filesystem. Nothing here is persisted: the two
-- files live in the temporary directory and are removed when the job ends.
local fs = require("fs")
local json = require("json")
local threading = require("threading")
local Log = require("beat.log")
local platform = require("beat.platform")
local workerProcess = require("beat.workers.process")

-- How much of the worker's output one read may take, and how many decoded tracks may wait. A scan
-- can write a whole library in a fraction of a second; reading it whole would hold every decoded
-- event at once, and a call that decoded a megabyte would hold a frame for as long as it took. A
-- chunk is small enough that one poll stays a few milliseconds on a fast local scan.
local READ_CHUNK = 64 * 1024
local QUEUE_LIMIT = 256

local ScanJob = {}
ScanJob.__index = ScanJob

---@class beat.ScanJob
---@field root string
---@field output string
---@field cancelFile string
---@field offset number
---@field buffer string
---@field queued table[]
---@field latest beat.ScanProgress?
---@field done boolean
---@field cancelled boolean
---@field error string?
---@field changed boolean
---@field child process.Child? # The coordinator process, until it exits
---@field exitCode number? # How the coordinator exited, once it has
---@field decodeErrors number # Lines the worker wrote that were not JSON this could read
---@field thread threading.Handle? # The scan's thread, where it runs on one: an Android app cannot start a copy of itself

--- A job over an already-known output path, which is also what the tests write by hand.
---@param root string
---@param output string
---@param cancelFile string
---@return beat.ScanJob
function ScanJob.new(root, output, cancelFile)
	return setmetatable(
		{
			root = root,
			output = output,
			cancelFile = cancelFile,
			offset = 0,
			buffer = "",
			queued = {},
			latest = { phase = "enumerate", files = 0, inspected = 0, tracks = 0, skipped = 0, errors = {}, current = nil },
			done = false,
			cancelled = false,
			error = nil,
			changed = false,
			decodeErrors = 0
		},
		ScanJob
	)
end

--- A scan in a coordinator process, which starts the inspectors.
---@param root string
---@return beat.ScanJob
local function startWorker(root)
	local output = os.tmpname() .. "-beat-scan.jsonl"
	local cancelFile = os.tmpname() .. "-beat-scan.cancel"
	fs.delete(output)
	fs.delete(cancelFile)

	local job = ScanJob.new(root, output, cancelFile)
	local child, err = workerProcess.spawn(
		{ BEAT_WORKER = "scan", BEAT_SCAN_ROOT = root, BEAT_SCAN_OUTPUT = output, BEAT_SCAN_CANCEL = cancelFile }
	)

	if child == nil then
		job.done = true
		job.error = "could not start the scan: " .. tostring(err)
		return job
	end

	job.child = child
	return job
end

--- What a scan thread runs: the folder walked and every track inspected, written as the lines a
--- coordinator process writes -- progress, a track, done, cancelled -- so the job reads both alike.
---@param root string
---@param output string
---@param cancelFile string
local function scanOnThread(root, output, cancelFile)
	return threading.spawn(function()
		local fs = require("fs")
		local json = require("json")
		local Scanner = require("beat.music.scan")
		local artwork = require("beat.music.artwork")
		local names = require("beat.music.names")

		local file = assert(io.open(output, "wb"))
		local function emit(value)
			local ok, line = pcall(json.encode, value)
			if ok then
				file:write(line, "\n")
				file:flush()
			end
		end

		local scanner = Scanner.new(root, { library = false })
		local covers = {}
		scanner.onTrack = function(info, entry, cover)
			local key = names.albumKey(info.tags, entry.dir)
			local coverCache = covers[key]
			if coverCache == nil then
				coverCache = false
				if info.hasPicture or cover ~= nil then
					coverCache = artwork.cacheCover(
						{ path = entry.path, hasPicture = info.hasPicture, coverPath = cover, modified = entry.modifyTime },
						512,
						root
					) or false
				end
				covers[key] = coverCache
			end
			emit({ type = "track", info = info, entry = entry, cover = cover, coverCache = coverCache or nil })
		end

		local clock = os.clock
		local lastProgress = 0
		while not scanner:isDone() do
			if fs.isfile(cancelFile) then
				emit({ type = "cancelled" })
				file:close()
				return
			end
			scanner:step(0.05, clock)
			if clock() - lastProgress >= 0.1 then
				local progress = scanner:progress()
				progress.type = "progress"
				emit(progress)
				lastProgress = clock()
			end
		end

		emit({ type = "done", skipped = scanner.skipped, errors = scanner.errors })
		file:close()
	end)
end

--- A scan on a thread of this process: Android starts an app from the zygote, and an APK has no
--- executable a second process could be started from.
---@param root string
---@return beat.ScanJob
local function startThread(root)
	local output = os.tmpname() .. "-beat-scan.jsonl"
	local cancelFile = os.tmpname() .. "-beat-scan.cancel"
	fs.delete(output)
	fs.delete(cancelFile)

	local job = ScanJob.new(root, output, cancelFile)
	job.thread = scanOnThread(root, output, cancelFile)
	return job
end

---@param root string
---@return beat.ScanJob
function ScanJob.start(root)
	if platform.android then return startThread(root) end
	return startWorker(root)
end

--- A worker line as the Lua table the app reads. A function rather than a closure per line: this
--- is the hot loop of a scan, and a new closure for every track is allocation and a trace abort.
---@param line string
---@return table?
local function decodeEvent(line)
	return json.decode(line):unpack()
end

--- Reads what the worker wrote since the last poll, keeping a partial last line for the next one.
---@param self beat.ScanJob
---@return boolean more # Whether there may be output left: something was read, or the queue is full
function ScanJob:read()
	if #self.queued >= QUEUE_LIMIT then return true end

	-- Binary, so the offset counts bytes: text mode on Windows reads "\r\n" as one character, and
	-- an offset that falls behind the file re-reads the end of what was already taken.
	local file = io.open(self.output, "rb")
	if file == nil then return false end

	file:seek("set", self.offset)
	local data = file:read(READ_CHUNK) or ""
	file:close()
	if data == "" then return false end

	self.offset += #data
	-- One pass over the new bytes: the line is cut out and the rest of the buffer is copied once at
	-- the end, rather than a copy of everything left per line, which made a full library quadratic.
	local buffer = self.buffer .. data
	local cursor = 1

	while true do
		local stop = buffer:find("\n", cursor, true)
		if stop == nil then break end
		local line = buffer:sub(cursor, stop - 1)
		cursor = stop + 1
		if #line > 0 and line:byte(-1) == 13 then line = line:sub(1, -2) end

		if line ~= "" then
			local ok, event = pcall(decodeEvent, line)
			if not ok then
				self.decodeErrors += 1
				if self.decodeErrors <= 3 then
					Log.write("error", "scan output could not be read: " .. tostring(event))
				end
			elseif type(event) == "table" then
				---@cast event table
				if event.type == "progress" then
					self.latest = event
					self.changed = true
				elseif event.type == "done" then
					self.done = true
					local latest = self.latest
					if latest ~= nil then
						latest.phase = "done"
						latest.skipped = event.skipped or latest.skipped
						latest.errors = event.errors or latest.errors
					end
					self.changed = true
				elseif event.type == "cancelled" then
					self.done = true
					self.cancelled = true
					self.changed = true
				elseif event.type == "error" then
					self.done = true
					self.error = event.message or "scan failed"
					self.changed = true
				else
					self.queued[#self.queued + 1] = event
				end
			end
		end
	end

	self.buffer = cursor <= #buffer and buffer:sub(cursor) or ""
	return true
end

--- The tracks and progress the app has not seen yet. At most `limit` events are handed over in
--- one tick, so a fast local scan cannot make a single frame add thousands of rows.
---@param limit number?
---@param self beat.ScanJob
---@return table[] events
---@return boolean changed
function ScanJob:poll(limit)
	limit = limit or 32

	if self.child ~= nil then
		local code = self.child:poll()
		if code ~= nil then
			if code ~= 0 then
				Log.write("error", "scan worker exited with code " .. tostring(code))
			end

			self.child = nil
			self.exitCode = code
		end
	end

	-- A thread that has ended is joined once; one that raised says why, and its output is still
	-- read to the end below.
	local thread = self.thread
	if thread ~= nil and thread:done() then
		self.thread = nil
		local ok, err = pcall(thread.join, thread)
		if not ok then
			Log.write("error", "scan thread failed: " .. tostring(err))
		end
		self.exitCode = ok and 0 or 1
	end

	-- A worker that exits without saying it finished -- it crashed, or never started its scan --
	-- leaves nothing more to wait for once its output has been read to the end.
	if not self:read() and self.exitCode ~= nil and not self.done then
		self.done = true
		self.error = "the scan stopped unexpectedly (exit code " .. tostring(self.exitCode) .. ")"
		self.changed = true
	end

	local events = {}
	while #events < limit and #self.queued > 0 do
		events[#events + 1] = table.remove(self.queued, 1) --[[@as table]]
	end

	local changed = self.changed or #events > 0
	self.changed = false
	return events, changed
end

---@param self beat.ScanJob
---@return beat.ScanProgress
function ScanJob:progress()
	return self.latest or {
		phase = "enumerate",
		files = 0,
		inspected = 0,
		tracks = 0,
		skipped = 0,
		errors = {},
		current = nil
	}
end

---@param self beat.ScanJob
---@return boolean
function ScanJob:isDone()
	return self.done
end

---@param self beat.ScanJob
---@return boolean
function ScanJob:hasPending()
	return #self.queued > 0
end

--- Asks the worker to stop: the cancel file is what it reads between files, and the coordinator is
--- killed at once rather than waited for. Its inspectors notice that their parent is gone and stop
--- on their own; see `beat.workers.parent`.
---@param self beat.ScanJob
---@return boolean
function ScanJob:cancel()
	fs.write(self.cancelFile, "1")

	if self.child ~= nil then
		self.child:kill(true)
		self.child:poll()
		self.child = nil
	end

	self.changed = true
	return true
end

---@param self beat.ScanJob
function ScanJob:close()
	fs.delete(self.output)
	fs.delete(self.cancelFile)
end

return ScanJob
