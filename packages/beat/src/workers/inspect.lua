-- One shard of a parallel scan: reads file entries from the coordinator's manifest, inspects the
-- audio headers, writes track events, and fills the local cover cache. Several of these run at
-- once so a high-latency mount can keep more than one file read in flight.
--
-- It runs in a copy of beat started with BEAT_WORKER=inspect (see `beat.workers.process`), with
-- the shard's paths in the environment.
local env = require("env")
local fs = require("fs")
local parent = require("beat.workers.parent")
local json = require("json")
local names = require("beat.music.names")
local artwork = require("beat.music.artwork")
local Log = require("beat.log")
local audio = require("treble.audio")
local time = require("wonderland.time")

local manifestPath = assert(env.var("BEAT_SCAN_MANIFEST"), "no scan manifest")
local outputPath = assert(env.var("BEAT_SCAN_OUTPUT"), "no scan output")
local cancelFile = assert(env.var("BEAT_SCAN_CANCEL"), "no scan cancel file")
local cacheRoot = assert(env.var("BEAT_SCAN_ROOT"), "no scan root")

local file = assert(io.open(outputPath, "wb"))

-- A track line is the JSON the app reads: the coordinator forwards it untouched, so the only thing
-- written for one is the encoded event and a newline. Everything else this shard has to say --
-- progress, done, an error -- is a status line, marked with a leading 1, a byte JSON never starts
-- with, so the two need no second file and no second pipe.
---@param value beat.MessageFields
local function emitStatus(value)
	file:write("\1", json.encode(value), "\n")
	file:flush()
end

-- Error text travels through JSON, which is UTF-8: a malformed tag byte or an ANSI Windows path
-- must not make the report of a failure fail too.
---@param value any
local function clean(value)
	return (tostring(value):gsub("[%z\1-\31\127-\255]", "?"))
end

-- A tag value that is not UTF-8 cannot travel as JSON. treble decodes ID3 text to UTF-8, but a
-- WAV's RIFF INFO chunk and a Vorbis comment are handed over as the bytes the file stores, and a
-- tagger can write those in any code page. Such a value is dropped, and the track falls back to
-- its file name for it, rather than the event taking the whole shard down.
---@param info table
local function dropUnsendableTags(info)
	local tags = info.tags
	if type(tags) ~= "table" then return end
	for key, value in pairs(tags) do
		if type(value) == "string" and not pcall(json.encode, value) then tags[key] = nil end
	end
end

local COVER_SIZE = 512
local PROGRESS_EVERY = 32
local PROGRESS_SECONDS = 0.25

local cached = {}
local triedFolder = {}
local usedCovers = {}
local inspected = 0
local tracks = 0
local skipped = 0
local errors = {}
local current = nil

---@param path string
---@param message string
local function recordError(path, message)
	skipped += 1
	if #errors < 100 then
		errors[#errors + 1] = { path = clean(path), message = clean(message) }
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
		modifyTime = stat?.modifyTime
	}

	local ok, info = pcall(audio.inspect, entry.path)
	if not ok or info == nil then
		recordError(entry.path, ok ? "not an audio file this library reads" : tostring(info))
		return
	end

	local key = names.albumKey(info.tags, entry.dir)
	local coverCache = cached[key]
	if coverCache == nil then
		if info.hasPicture then
			coverCache = artwork.cacheCover(
				{ path = entry.path, hasPicture = true, coverPath = entry.cover, modified = fileEntry.modifyTime },
				COVER_SIZE,
				cacheRoot
			)
		elseif entry.cover ~= nil and not triedFolder[key] then
			triedFolder[key] = true
			local coverStat = fs.stat(entry.cover)
			coverCache = artwork.cacheCover(
				{
					path = entry.path,
					hasPicture = false,
					coverPath = entry.cover,
					modified = fileEntry.modifyTime,
					coverModified = coverStat?.modifyTime
				},
				COVER_SIZE,
				cacheRoot
			)
		end

		if coverCache ~= nil then cached[key] = coverCache end
	end
	if coverCache ~= nil then usedCovers[coverCache] = true end

	dropUnsendableTags(info)
	local sent, encoded = pcall(
		json.encode,
		{ type = "track", info = info, entry = fileEntry, cover = entry.cover, coverCache = coverCache }
	)
	if not sent then
		recordError(entry.path, "skipped: its tags are not UTF-8")
		return
	end

	tracks += 1
	file:write(encoded, "\n")
	file:flush()
end

local started = time.now()
local lastProgress = started

local orphaned = false

local ok, err = pcall(function()
	for line in assert(io.lines(manifestPath)) do
		-- The coordinator is gone -- the window closed or was killed -- so no reader wants this
		-- shard and its parent cannot stop it any more. The cancel file is what a cancel asks for;
		-- this is what the process ending looks like from here.
		if parent.gone() then
			orphaned = true
			break
		end
		if fs.isfile(cancelFile) then
			emitStatus({ type = "cancelled" })
			return
		end

		local decoded = json.decode(line):unpack()
		if type(decoded) ~= "table" or type(decoded.path) ~= "string" then
			recordError(manifestPath, "invalid manifest entry")
		else
			---@cast decoded beat.ScanEntry
			current = decoded.path
			inspect(decoded)
			inspected += 1
		end

		local now = time.now()
		if inspected % PROGRESS_EVERY == 0 or now - lastProgress >= PROGRESS_SECONDS then
			emitStatus({ type = "progress", inspected = inspected, tracks = tracks, skipped = skipped, current = current ~= nil ? clean(current) : nil })
			lastProgress = now
		end
	end
end)

if orphaned then
	-- Nothing to say: the process that would read it is gone.
elseif not ok then
	Log.write("error", "scan inspector failed on " .. tostring(current) .. ": " .. tostring(err))
	emitStatus({ type = "error", message = "Could not read " .. clean(current or "a track") .. ": " .. clean(err) })
else
	local covers = {}
	for cover in pairs(usedCovers) do covers[#covers + 1] = cover end
	emitStatus({ type = "done", inspected = inspected, tracks = tracks, skipped = skipped, errors = errors, covers = covers })
end

file:close()
