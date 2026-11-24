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
local parent = require("beat.workers.parent")
local workerProcess = require("beat.workers.process")
local time = require("wonderland.time")

local root = assert(env.var("BEAT_SCAN_ROOT"), "no scan root")
local output = assert(env.var("BEAT_SCAN_OUTPUT"), "no scan output")
local cancelFile = assert(env.var("BEAT_SCAN_CANCEL"), "no scan cancel file")
---@type string?
local knownFile = env.var("BEAT_SCAN_KNOWN")

local WORKERS = tonumber(os.getenv("BEAT_SCAN_WORKERS") or "") or 4
WORKERS = math.max(1, math.min(16, WORKERS))

--- Waits without spending the wait: the loop below asks its workers and its parent every few
--- milliseconds, and a busy spin there would take a core from the inspectors it is reading.
local sleep = workerProcess.sleep

local file = assert(io.open(output, "wb"))
---@param value beat.MessageFields
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
local function sendable(value)
	return (pcall(json.encode, value))
end

--- A name that can be shown and sent, with every byte that kept it from being UTF-8 replaced.
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

local temps = {}
local activeChildren = {}
local exitedChildren = {}

---@param suffix string
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

---@class InspectWorker
---@field child process.Child
---@field output string
---@field handle file? # The shard's output, open across passes so a fast scan is not an open a millisecond
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
		handle = nil,
		offset = 0,
		buffer = "",
		done = false,
		exited = false,
		exitCode = nil,
		error = nil,
		inspected = 0,
		skipped = 0,
		current = nil,
		errors = {}
	}
end

local usedCovers = {}
local forwarded = 0

-- One pass reads at most this much of a shard, and a line not finished yet is kept for the next
-- pass. A scan that writes a whole library in a second arrives in a few passes rather than one
-- allocation of the whole file.
local READ_PASS = 512 * 1024

--- A status line, without the byte that told the reader it was one. Track lines are the JSON the
--- app reads already, so only these are decoded.
---@param line string
---@return table?
local function decodeStatus(line)
	return json.decode(line:sub(2)):unpack()
end

local function closeWorker(worker)
	if worker.handle ~= nil then
		worker.handle:close()
		worker.handle = nil
	end
end

--- Read whatever this shard has written since the last pass. A track line is copied through
--- untouched: decoding and re-encoding every track was what made this process allocate as much as
--- the inspectors it reads. Status lines -- progress, done, an error -- carry a leading 1, a byte
--- JSON never starts with, and carry the cover list so the cache can be pruned without asking each
--- track.
---@param worker InspectWorker
---@return boolean more # Whether the pass read anything, so an exited worker can be drained
local function readWorker(worker)
	local input = worker.handle
	if input == nil then
		input = io.open(worker.output, "rb")
		if input == nil then return false end
		worker.handle = input
	end

	-- Binary, so the offset counts bytes: see `ScanJob:read`. Seeking also clears a previous read's
	-- end-of-file, so a pass after the inspector wrote more sees what it wrote.
	input:seek("set", worker.offset)
	local data = input:read(READ_PASS) or ""
	if data == "" then return false end

	worker.offset += #data
	local buffer = worker.buffer .. data
	local cursor, moved = 1, false

	while true do
		local stop = buffer:find("\n", cursor, true)
		if stop == nil then break end
		local line = buffer:sub(cursor, stop - 1)
		cursor = stop + 1

		if #line > 0 then
			if line:byte(1) == 1 then
				local ok, event = pcall(decodeStatus, line)
				if not ok then
					Log.write("error", "scan inspector status could not be read: " .. tostring(event))
				elseif type(event) == "table" then
					---@cast event table
					if event.type == "progress" then
						worker.inspected = event.inspected or worker.inspected
						worker.skipped = event.skipped or worker.skipped
						worker.current = event.current or worker.current
					elseif event.type == "done" then
						worker.done = true
						worker.inspected = event.inspected or worker.inspected
						worker.skipped = event.skipped or worker.skipped
						worker.errors = event.errors or worker.errors
						for _, cover in ipairs(event.covers or {}) do usedCovers[cover] = true end
					elseif event.type == "cancelled" then
						worker.done = true
					elseif event.type == "error" then
						worker.error = event.message or "scan worker failed"
						worker.done = true
					end
				end
			else
				forwarded += 1
				file:write(line, "\n")
				moved = true
			end
		end
	end

	worker.buffer = cursor <= #buffer and buffer:sub(cursor) or ""
	if moved then file:flush() end
	return true
end

---@param workers InspectWorker[]
---@return number inspected
---@return number skipped
---@return string? current
local function totals(workers)
	local inspected, skipped, current = 0, 0, nil
	for _, worker in ipairs(workers) do
		inspected += worker.inspected
		skipped += worker.skipped
		current = worker.current or current
	end
	return inspected, skipped, current
end

local ok, err = pcall(function()
	emit({ type = "progress", phase = "enumerate", files = 0, inspected = 0, tracks = 0, skipped = 0, errors = {}, current = printable(root) })

	local scanner = Scanner.new(root, { library = false })
	local lastProgress = time.now()
	while scanner.phase == "enumerate" do
		-- The window that started this scan is gone: its reader is gone with it, and the folder
		-- walk is only ever done for that reader. The inspectors have not been started yet.
		if parent.gone() then return end
		if fs.isfile(cancelFile) then
			emit({ type = "cancelled" })
			return
		end

		scanner:enumerateStep(0.05, time.now)
		local now = time.now()
		if now - lastProgress >= 0.1 then
			local progress = scanner:progress()
			emit({ type = "progress", phase = "enumerate", files = progress.files, inspected = 0, tracks = 0, skipped = 0, errors = {}, current = printable(progress.current) })
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
			enumSkipped += 1
			enumErrors[#enumErrors + 1] = { path = printable(entry.path), message = NOT_UTF8 }
		end
	end
	emit({ type = "progress", phase = "inspect", files = #entries, inspected = 0, tracks = 0, skipped = enumSkipped, errors = {}, current = nil })

	if #entries == 0 then
		emit({ type = "done", skipped = enumSkipped, errors = enumErrors })
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

			local vars = { BEAT_WORKER = "inspect", BEAT_SCAN_MANIFEST = manifest, BEAT_SCAN_OUTPUT = shardOutput, BEAT_SCAN_CANCEL = cancelFile, BEAT_SCAN_ROOT = root }
			if knownFile ~= nil then vars.BEAT_SCAN_KNOWN = knownFile end
			local child, spawnErr = workerProcess.spawn(vars)
			if child == nil then
				error("could not start scan inspector " .. at .. ": " .. tostring(spawnErr))
			end
			activeChildren[#activeChildren + 1] = child
			workers[#workers + 1] = newWorker(child, shardOutput)
		end
	end

	local lastReport = time.now()
	while true do
		-- The app is gone: nobody will read another event, and this process is the one that holds
		-- the inspectors. Returning here runs `cleanup`, which stops them.
		if parent.gone() then return end
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
			if not worker.exited then allDone = false end
		end

		local now = time.now()
		if now - lastReport >= 0.1 then
			local inspected, skipped, current = totals(workers)
			emit({ type = "progress", phase = "inspect", files = #entries, inspected = inspected, tracks = forwarded, skipped = skipped, errors = {}, current = current })
			lastReport = now
		end

		if allDone then break end
		sleep(20)
	end

	-- An inspector can write more between the poll that reaped it and the read that follows, and a
	-- pass above stops at `READ_PASS`: drain each shard to its end before asking what it reported.
	for _, worker in ipairs(workers) do
		while readWorker(worker) do end
		closeWorker(worker)
	end

	local errors = {}
	local fatal = nil
	local inspected, skipped = totals(workers)
	skipped += enumSkipped
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

	emit({ type = "progress", phase = "inspect", files = #entries, inspected = inspected, tracks = forwarded, skipped = skipped, errors = {}, current = nil })
	emit({ type = "done", skipped = skipped, errors = errors })
	artworkCache.prune(root, usedCovers)
end)

if not ok then
	emit({ type = "error", message = printable(tostring(err)) })
end

cleanup()
file:close()
