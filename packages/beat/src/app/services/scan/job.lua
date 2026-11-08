-- A scan in a process of its own.
--
-- The worker walks the folder and writes one JSON line per inspected track; this side reads what
-- has arrived since the last tick and hands the app the tracks. The window keeps drawing, playing
-- and searching while the worker waits on a slow filesystem. Nothing here is persisted: the two
-- files live in the temporary directory and are removed when the job ends.
local fs = require("fs")
local json = require("json")
local Log = require("beat.log")
local workerProcess = require("beat.workers.process")

-- How much of the worker's output one tick may read, and how many decoded tracks may wait.
-- A scan can write a whole library in a fraction of a second; reading it whole would hold every
-- decoded event at once. The queue is drained `limit` at a time, so it only refills when it is
-- nearly empty.
local READ_CHUNK = 32 * 1024
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

---@param root string
---@return beat.ScanJob
function ScanJob.start(root)
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
	self.buffer ..= data

	while true do
		local line, rest = self.buffer:match("^(.-)\r?\n(.*)$")
		if line == nil then break end
		self.buffer = rest

		if line ~= "" then
			local ok, event = pcall(|| -> json.decode(line):unpack())
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
