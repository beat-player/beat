-- The scan's coordinator process: walks the folder once, splits the files into directory-balanced
-- shards, and starts a pool of inspector processes. Each inspector reads a shard's audio headers
-- and writes track events; this process forwards them to the app as they arrive.
--
-- Several readers work at once, which is what matters on a mount where each read is a round trip.
-- The window never touches the music folder: it reads this process's local JSONL output.
--
-- It runs in a copy of beat started with BEAT_WORKER=scan (see `beat.workers.process`), and starts
-- its inspectors the same way.
local env = require("env")
local fs = require("fs")
local json = require("json")
local Scanner = require("beat.music.scan")
local artworkCache = require("beat.music.artwork_cache")
local Log = require("beat.log")
local workerProcess = require("beat.workers.process")
local time = require("wonderland.time")
local ffi = require("ffi")

local root = assert(env.var("BEAT_SCAN_ROOT"), "no scan root")
local output = assert(env.var("BEAT_SCAN_OUTPUT"), "no scan output")
local cancelFile = assert(env.var("BEAT_SCAN_CANCEL"), "no scan cancel file")

local WORKERS = tonumber(os.getenv("BEAT_SCAN_WORKERS") or "") or 4
WORKERS = math.max(1, math.min(16, WORKERS))

---@type fun(milliseconds: number)
local sleep
if jit.os == "Windows" then
	ffi.cdef [[void Sleep(unsigned int);]]
	local kernel32 = ffi.load("kernel32")
	---@param milliseconds number
	local function windowsSleep(milliseconds)
		kernel32.Sleep(ffi.cast("unsigned int", math.floor(milliseconds)))
	end
	sleep = windowsSleep
else
	ffi.cdef [[int usleep(unsigned int);]]
	---@param milliseconds number
	local function posixSleep(milliseconds)
		ffi.C.usleep(math.floor(milliseconds * 1000))
	end
	sleep = posixSleep
end

local file = assert(io.open(output, "wb"))
local function emit(value)
	file:write(json.encode(value), "\n")
	file:flush()
end

-- What travels between the scan's processes is JSON, which only carries UTF-8. lde's `fs` reads
-- Windows names through the ANSI calls, so a name outside ASCII arrives in the system code page
-- ("Antônio" as "Ant\xF4nio") and cannot be sent. Such files are left out and reported until
-- names arrive as UTF-8.
local NOT_UTF8 = "skipped: its name is not UTF-8"

---@param value string
---@return boolean
local function sendable(value)
	return (pcall(json.encode, value))
end

--- A name that can be shown and sent, with every byte that kept it from being UTF-8 replaced.
---@param value string?
---@return string?
local function printable(value)
	if value == nil or sendable(value) then return value end
	return (value:gsub("[\128-\255]", "\239\191\189"))
end

---@param failures { path: string, message: string }[]
---@return { path: string, message: string }[]
local function printableFailures(failures)
	local out = {}
	for at, failure in ipairs(failures) do
			out[at] = { path = printable(failure.path), message = printable(failure.message)}
		end
	return out
end

local temps = {}
local activeChildren = {}
local exitedChildren = {}

---@param suffix string
---@return string
local function temp(suffix)
	local path = os.tmpname() .. suffix
	temps[#temps + 1] = path
	return path
end

local function cleanup()
	for _, child in ipairs(activeChildren) do
		if not exitedChildren[child] then pcall(child.kill, child, true) end
	end
	for _, path in ipairs(temps) do fs.delete(path) end
end

local MAX_DIRECTORY_UNIT = 64

--- Distribute folders across shards so ordinary albums stay whole and their cover is cached once.
--- A directory with thousands of files is split into units; those are rare, and the atomic cover
--- cache write keeps two inspectors safe if they do race for the same album.
---@param entries beat.ScanEntry[]
---@param count number
---@return beat.ScanEntry[][]
local function shard(entries, count)
	local byDir = {}
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

	local units = {}
	for _, dir in ipairs(dirs) do
		local list = byDir[dir]
		if #list <= MAX_DIRECTORY_UNIT or count == 1 then
			units[#units + 1] = list
		else
			for at = 1, #list, MAX_DIRECTORY_UNIT do
				local chunk = {}
				for index = at, math.min(#list, at + MAX_DIRECTORY_UNIT - 1) do
					chunk[#chunk + 1] = list[index]
				end
				units[#units + 1] = chunk
			end
		end
	end

	table.sort(units, function(a, b) return #a > #b end)

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
		loads[best] = loads[best] + #unit
	end

	return shards
end

---@class InspectWorker
---@field child process.Child
---@field output string
---@field offset number
---@field buffer string
---@field done boolean
---@field exited boolean
---@field exitCode number?
---@field error string?
---@field inspected number
---@field skipped number
---@field current string?
---@field errors { path: string, message: string }[]

---@param child process.Child
---@param outputPath string
---@return InspectWorker
local function newWorker(child, outputPath)
	return {
		child = child,
		output = outputPath,
		offset = 0,
		buffer = "",
		done = false,
		exited = false,
		exitCode = nil,
		error = nil,
		inspected = 0,
		skipped = 0,
		current = nil,
		errors = {},
	}
end

local usedCovers = {}
local forwarded = 0

--- Read whatever this shard has written since the last read, forwarding each complete event.
---@param worker InspectWorker
local function readWorker(worker)
	-- Binary, so the offset is bytes: see `ScanJob:read`.
	local input = io.open(worker.output, "rb")
	if input == nil then return end

	input:seek("set", worker.offset)
	local data = input:read("*a") or ""
	input:close()
	if data == "" then return end

	worker.offset = worker.offset + #data
	worker.buffer = worker.buffer .. data

	while true do
		local line, rest = worker.buffer:match("^(.-)\r?\n(.*)$")
		if line == nil then break end
		worker.buffer = rest

		if line ~= "" then
			local ok, event = pcall(function() return json.decode(line):unpack() end)
			if not ok then
				Log.write("error", "scan inspector output could not be read: " .. tostring(event))
			elseif type(event) == "table" then
				---@cast event table
				if event.type == "track" then
					forwarded = forwarded + 1
					if event.coverCache ~= nil then usedCovers[event.coverCache] = true end
					emit(event)
				elseif event.type == "progress" then
					worker.inspected = event.inspected or worker.inspected
					worker.skipped = event.skipped or worker.skipped
					worker.current = event.current or worker.current
				elseif event.type == "done" then
					worker.done = true
					worker.inspected = event.inspected or worker.inspected
					worker.skipped = event.skipped or worker.skipped
					worker.errors = event.errors or worker.errors
				elseif event.type == "cancelled" then
					worker.done = true
				elseif event.type == "error" then
					worker.error = event.message or "scan worker failed"
					worker.done = true
				end
			end
		end
	end
end

---@param workers InspectWorker[]
---@return number inspected
---@return number skipped
---@return string? current
local function totals(workers)
	local inspected, skipped, current = 0, 0, nil
	for _, worker in ipairs(workers) do
		inspected = inspected + worker.inspected
		skipped = skipped + worker.skipped
		current = worker.current or current
	end
	return inspected, skipped, current
end

local ok, err = pcall(function()
	emit({ type = "progress", phase = "enumerate", files = 0, inspected = 0, tracks = 0, skipped = 0,
		errors = {}, current = printable(root)})

	local scanner = Scanner.new(root, { library = false })
	local lastProgress = time.now()
	while scanner.phase == "enumerate" do
		if fs.isfile(cancelFile) then
			emit({ type = "cancelled" })
			return
		end

		scanner:enumerateStep(0.05, time.now)
		local now = time.now()
		if now - lastProgress >= 0.1 then
			local progress = scanner:progress()
			emit({ type = "progress", phase = "enumerate", files = progress.files, inspected = 0,
				tracks = 0, skipped = 0, errors = {}, current = printable(progress.current)})
			lastProgress = now
		end
	end

	local entries = {}
	local enumSkipped = scanner.skipped
	local enumErrors = printableFailures(scanner.errors)
	for _, entry in ipairs(scanner:entries()) do
			if sendable(entry.path) then
				entries[#entries + 1] = entry
			else
				enumSkipped = enumSkipped + 1
				enumErrors[#enumErrors + 1] = { path = printable(entry.path), message = NOT_UTF8}
			end
		end
	emit({ type = "progress", phase = "inspect", files = #entries, inspected = 0, tracks = 0,
		skipped = enumSkipped, errors = {}, current = nil})

	if #entries == 0 then
		emit({ type = "done", skipped = enumSkipped, errors = enumErrors})
		return
	end

	local shards = shard(entries, math.min(WORKERS, #entries))
	local workers = {}
	for at, shardEntries in ipairs(shards) do
		if #shardEntries > 0 then
			local manifest = temp("-manifest.jsonl")
			local shardOutput = temp("-tracks.jsonl")
			local listing = assert(io.open(manifest, "w"))
			for _, entry in ipairs(shardEntries) do listing:write(json.encode(entry), "\n") end
			listing:close()

			local child, spawnErr = workerProcess.spawn({
				BEAT_WORKER = "inspect",
				BEAT_SCAN_MANIFEST = manifest,
				BEAT_SCAN_OUTPUT = shardOutput,
				BEAT_SCAN_CANCEL = cancelFile,
				BEAT_SCAN_ROOT = root,
			})
			if child == nil then
				error("could not start scan inspector " .. at .. ": " .. tostring(spawnErr))
			end
			activeChildren[#activeChildren + 1] = child
			workers[#workers + 1] = newWorker(child, shardOutput)
		end
	end

	local lastReport = time.now()
	while true do
		if fs.isfile(cancelFile) then
			for _, worker in ipairs(workers) do
				if not worker.exited then worker.child:kill(true) end
			end
			emit({ type = "cancelled" })
			return
		end

		local allDone = true
		for _, worker in ipairs(workers) do
			if not worker.exited then
				local code = worker.child:poll()
				if code ~= nil then
					worker.exited = true
					worker.exitCode = code
					exitedChildren[worker.child] = true
				end
			end

			readWorker(worker)
			if worker.exited then
				readWorker(worker)
				if #worker.buffer > 0 then worker.buffer = "" end
			else
				allDone = false
			end
		end

		local now = time.now()
		if now - lastReport >= 0.1 then
			local inspected, skipped, current = totals(workers)
			emit({ type = "progress", phase = "inspect", files = #entries, inspected = inspected,
				tracks = forwarded, skipped = skipped, errors = {}, current = current})
			lastReport = now
		end

		if allDone then break end
		sleep(20)
	end

	for _, worker in ipairs(workers) do
		readWorker(worker)
		if #worker.buffer > 0 then worker.buffer = "" end
	end

	local errors = {}
	local fatal = nil
	local inspected, skipped = totals(workers)
	skipped = skipped + enumSkipped
	for _, failure in ipairs(enumErrors) do errors[#errors + 1] = failure end
	for _, worker in ipairs(workers) do
		for _, failure in ipairs(worker.errors or {}) do errors[#errors + 1] = failure end
		if worker.error ~= nil then
			fatal = fatal or worker.error
		elseif not worker.done and worker.exitCode ~= nil and worker.exitCode ~= 0 then
			fatal = fatal or ("scan inspector exited with code " .. tostring(worker.exitCode))
		end
	end

	if fatal ~= nil then error(fatal) end

	emit({ type = "progress", phase = "inspect", files = #entries, inspected = inspected,
		tracks = forwarded, skipped = skipped, errors = {}, current = nil})
	emit({ type = "done", skipped = skipped, errors = errors})
	artworkCache.prune(root, usedCovers)
end)

if not ok then
	emit({ type = "error", message = printable(tostring(err))})
end

cleanup()
file:close()
