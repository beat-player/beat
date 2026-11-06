-- A scan in a process of its own.
--
-- The worker walks the folder and writes one JSON line per inspected track; this side reads what
-- has arrived since the last tick and hands the app the tracks. The window keeps drawing, playing
-- and searching while the worker waits on a slow filesystem. Nothing here is persisted: the two
-- files live in the temporary directory and are removed when the job ends.
local env = require("env")
local fs = require("fs")
local json = require("json")
local process = require("process")
local jit = require("jit")

-- How much of the worker's output one tick may read, and how many decoded tracks may wait.
-- A scan can write a whole library in a fraction of a second; reading it whole would hold every
-- decoded event at once. The queue is drained `limit` at a time, so it only refills when it is
-- nearly empty.
local READ_CHUNK = 32 * 1024
local QUEUE_LIMIT = 256

-- A source run passes the script's path as `arg[0]`; a compiled executable passes its own. That is
-- what says whether the tools are on disk or the program has to start its worker from itself.
local compiled = arg == nil or (arg[0] ~= nil and arg[0]:match("%.lua$") == nil)

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
---@field child process.Child? # The worker this process started, where the executable runs itself

---@param value string
---@return string
local function quote(value)
	if jit.os == "Windows" then
		return '"' .. value:gsub('"', '\\"') .. '"'
	end
	return "'" .. value:gsub("'", "'\\''") .. "'"
end

---@param root string
---@param output string
---@param cancelFile string
---@return string
local function commandFor(root, output, cancelFile)
	local worker = "tools/scan-worker.lua"
	local osName = jit.os or ""
	if osName == "Windows" then
		return 'start "" /b lde run ' .. worker .. " " .. quote(root) .. " " .. quote(output) .. " "
		.. quote(cancelFile)
	end
	return "lde run " .. worker .. " " .. quote(root) .. " " .. quote(output) .. " " .. quote(cancelFile)
	.. " >/dev/null 2>&1 &"
end

--- A job over an already-known output path, which is also what the tests write by hand.
---@param root string
---@param output string
---@param cancelFile string
---@return beat.ScanJob
function ScanJob.new(root, output, cancelFile)
	return setmetatable({
	root = root,
	output = output,
	cancelFile = cancelFile,
	offset = 0,
	buffer = "",
	queued = {},
	latest = {
	phase = "enumerate",
	files = 0,
	inspected = 0,
	tracks = 0,
	skipped = 0,
	errors = {},
	current = nil,
	},
	done = false,
	cancelled = false,
	error = nil,
	changed = false,
	}, ScanJob)
end

---@param root string
---@return beat.ScanJob
function ScanJob.start(root)
	local output = os.tmpname() .. "-beat-scan.jsonl"
	local cancelFile = os.tmpname() .. "-beat-scan.cancel"
	fs.delete(output)
	fs.delete(cancelFile)

	local job = ScanJob.new(root, output, cancelFile)
	-- A compiled executable has no `lde` or `tools/` beside it: it starts its worker by running
	-- itself again with the paths in the environment. A source run keeps using the tools, where
	-- `lde run` is the thing that already exists.
	if compiled then
		local child, err = process.spawn(assert(env.execPath()), {}, {
			env = {
				BEAT_WORKER = "scan",
				BEAT_SCAN_ROOT = root,
				BEAT_SCAN_OUTPUT = output,
				BEAT_SCAN_CANCEL = cancelFile,
			},
			stdout = "null",
			stderr = "null",
		})

		if child == nil then
			job.done = true
			job.error = "could not start the scan: " .. tostring(err)
			return job
		end

		job.child = child
	else
		os.execute(commandFor(root, output, cancelFile))
	end

	return job
end

--- Reads what the worker wrote since the last poll, keeping a partial last line for the next one.
---@param self beat.ScanJob
function ScanJob:read()
	if #self.queued >= QUEUE_LIMIT then return end

	local file = io.open(self.output, "r")
	if file == nil then return end

	file:seek("set", self.offset)
	local data = file:read(READ_CHUNK) or ""
	file:close()
	if data == "" then return end

	self.offset = self.offset + #data
	self.buffer = self.buffer .. data

	while true do
		local line, rest = self.buffer:match("^(.-)\n(.*)$")
		if line == nil then break end
		self.buffer = rest

		if line ~= "" then
			local ok, event = pcall(function() return json.decode(line):unpack() end)
			if ok and type(event) == "table" then
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
end

--- The tracks and progress the app has not seen yet. At most `limit` events are handed over in
--- one tick, so a fast local scan cannot make a single frame add thousands of rows.
---@param limit number?
---@param self beat.ScanJob
---@return table[] events
---@return boolean changed
function ScanJob:poll(limit)
	limit = limit or 32

	if self.child ~= nil and self.child:poll() ~= nil then
		self.child = nil
	end

	self:read()

	local events = {}
	while #events < limit and #self.queued > 0 do
		events[#events + 1] = table.remove(self.queued, 1)
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
	current = nil,
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
