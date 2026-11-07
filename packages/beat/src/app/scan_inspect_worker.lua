-- One shard of a parallel scan: reads file entries from the coordinator's manifest, inspects the
-- audio headers, writes track events, and fills the local cover cache. Several of these run at
-- once so a high-latency mount can keep more than one file read in flight.
--
-- It runs in a copy of beat started with BEAT_WORKER=inspect (see `beat.app.worker_process`), with
-- the shard's paths in the environment.
local env = require("env")
local fs = require("fs")
local json = require("json")
local core = require("beat-core")
local Log = require("beat.app.log")
local audio = require("treble.audio")
local time = require("wonderland.time")

local manifestPath = assert(env.var("BEAT_SCAN_MANIFEST"), "no scan manifest")
local outputPath = assert(env.var("BEAT_SCAN_OUTPUT"), "no scan output")
local cancelFile = assert(env.var("BEAT_SCAN_CANCEL"), "no scan cancel file")
local cacheRoot = assert(env.var("BEAT_SCAN_ROOT"), "no scan root")

local file = assert(io.open(outputPath, "w"))
local function emit(value)
	file:write(json.encode(value), "\n")
	file:flush()
end

-- Error text travels through JSON, which is UTF-8: a malformed tag byte or an ANSI Windows path
-- must not make the report of a failure fail too.
---@param value any
---@return string
local function clean(value)
	return (tostring(value):gsub("[%z\1-\31\127-\255]", "?"))
end

local COVER_SIZE = 512
local PROGRESS_EVERY = 32
local PROGRESS_SECONDS = 0.25

local cached = {}
local triedFolder = {}
local inspected = 0
local tracks = 0
local skipped = 0
local errors = {}
local current = nil

---@param path string
---@param message string
local function recordError(path, message)
	skipped = skipped + 1
	if #errors < 100 then
		errors[#errors + 1] = { path = clean(path), message = clean(message)}
	end
end

---@param entry beat.ScanEntry
local function inspect(entry)
	local stat = fs.stat(entry.path)
	local fileEntry = {
	path = entry.path,
	dir = entry.dir,
	name = entry.name,
	ext = entry.ext,
	modifyTime = stat and stat.modifyTime or nil,
	}

	local ok, info = pcall(audio.inspect, entry.path)
	if not ok or info == nil then
		recordError(entry.path, ok and "not an audio file this library reads" or tostring(info))
		return
	end

	local key = core.util.albumKey(info.tags, entry.dir)
	local coverCache = cached[key]
	if coverCache == nil then
		if info.hasPicture then
			coverCache = core.art.cacheCover({
				path = entry.path,
				hasPicture = true,
				coverPath = entry.cover,
				modified = fileEntry.modifyTime,
			}, COVER_SIZE, cacheRoot)
		elseif entry.cover ~= nil and not triedFolder[key] then
			triedFolder[key] = true
			local coverStat = fs.stat(entry.cover)
			coverCache = core.art.cacheCover({
				path = entry.path,
				hasPicture = false,
				coverPath = entry.cover,
				modified = fileEntry.modifyTime,
				coverModified = coverStat and coverStat.modifyTime or nil,
			}, COVER_SIZE, cacheRoot)
		end

		if coverCache ~= nil then cached[key] = coverCache end
	end

	tracks = tracks + 1
	emit({ type = "track", info = info, entry = fileEntry, cover = entry.cover, coverCache = coverCache })
end

local started = time.now()
local lastProgress = started

local ok, err = pcall(function()
	for line in assert(io.lines(manifestPath)) do
		if fs.isfile(cancelFile) then
			emit({ type = "cancelled" })
			return
		end

		local decoded = json.decode(line):unpack()
		if type(decoded) ~= "table" or type(decoded.path) ~= "string" then
			recordError(manifestPath, "invalid manifest entry")
		else
			---@cast decoded beat.ScanEntry
			current = decoded.path
			inspect(decoded)
			inspected = inspected + 1
		end

		local now = time.now()
		if inspected % PROGRESS_EVERY == 0 or now - lastProgress >= PROGRESS_SECONDS then
			emit({ type = "progress", inspected = inspected, tracks = tracks, skipped = skipped,
				current = current ~= nil and clean(current) or nil})
			lastProgress = now
		end
	end
end)

if not ok then
	Log.write("error", "scan inspector failed on " .. tostring(current) .. ": " .. tostring(err))
	emit({ type = "error",
		message = "Could not read " .. clean(current or "a track") .. ": " .. clean(err) })
else
	emit({ type = "done", inspected = inspected, tracks = tracks, skipped = skipped, errors = errors})
end

file:close()
