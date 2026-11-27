-- One shard of a scan, on a thread of its own: reads the files the coordinator handed it, pushes
-- the tracks it finds back through a channel, and fills the local cover cache. Four of these run
-- at once so a high-latency mount keeps more than one file read in flight.
--
-- The shard and what the library already knows about its files arrive as the thread's own copies;
-- nothing here reads the app's tables. Closing the channel is what a cancelled scan looks like
-- from inside: every push then answers false, and the shard stops at the next file.
local fs = require("fs")
local json = require("json")
local threading = require("threading")
local names = require("beat.music.names")
local artwork = require("beat.music.artwork")
local audio = require("treble.audio")
local time = require("wonderland.time")

local Inspect = {}

local COVER_SIZE = artwork.CACHE_SIZE
local PROGRESS_EVERY = 32
local PROGRESS_SECONDS = 0.25

-- Error text is shown in a toast and on the settings screen: bytes that would draw as garbage are
-- replaced rather than passed through.
---@param value any
local function clean(value)
	return (tostring(value):gsub("[%z\1-\31\127-\255]", "?"))
end

-- The library cache is JSON, which only carries UTF-8. treble decodes ID3 text to UTF-8, but a
-- WAV's RIFF INFO chunk and a Vorbis comment are handed over as the bytes the file stores, and a
-- tagger can write those in any code page. Such a value is dropped, and the track falls back to
-- its file name for it, rather than making the whole library fail to save.
---@param info table
local function dropUnsendableTags(info)
	local tags = info.tags
	if type(tags) ~= "table" then return end
	for key, value in pairs(tags) do
		if type(value) == "string" and not pcall(json.encode, value) then tags[key] = nil end
	end
end

---@class beat.InspectorState
---@field events threading.Channel
---@field control threading.Channel
---@field index number
---@field root string
---@field known table<string, table>
---@field cached table<string, string|false>
---@field triedFolder table<string, boolean>
---@field usedCovers table<string, boolean>
---@field inspected number
---@field tracks number
---@field skipped number
---@field errors { path: string, message: string }[]
---@field current string?

---@param state beat.InspectorState
---@param path string
---@param message string
local function recordError(state, path, message)
	state.skipped += 1
	if #state.errors < 100 then
		state.errors[#state.errors + 1] = { path = clean(path), message = clean(message) }
	end
end

---@param state beat.InspectorState
---@param entry beat.ScanEntry
---@return boolean keepGoing # False when the channel closed, which is a cancelled scan
local function inspectOne(state, entry)
	local stat = fs.stat(entry.path)
	local fileEntry = {
		path = entry.path,
		dir = entry.dir,
		name = entry.name,
		ext = entry.ext,
		modifyTime = stat?.modifyTime
	}

	local record = state.known[entry.path]
	if record ~= nil then
		local cover = record.coverCache
		-- A cover the cache no longer holds is made again, so a rescan restores a cleaned cache.
		if record.modified == fileEntry.modifyTime
			and (cover == nil or (type(cover) == "string" and fs.isfile(cover))) then
			if type(cover) == "string" then state.usedCovers[cover] = true end
			state.tracks += 1
			return state.events:push({ type = "reused", record = record })
		end
	end

	local ok, info = pcall(audio.inspect, entry.path)
	if not ok or info == nil then
		recordError(state, entry.path, ok ? "not an audio file this library reads" : tostring(info))
		return true
	end

	local key = names.albumKey(info.tags, entry.dir, entry.path)
	local coverCache = state.cached[key]
	if coverCache == nil then
		if info.hasPicture then
			coverCache = artwork.cacheCover(
				{ path = entry.path, hasPicture = true, coverPath = entry.cover, modified = fileEntry.modifyTime },
				COVER_SIZE,
				state.root
			)
		elseif not names.isSingleKey(key) and entry.cover ~= nil and not state.triedFolder[key] then
			-- A single is its own album, so the picture beside it belongs to no album of its own.
			state.triedFolder[key] = true
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
				state.root
			)
		end

		if coverCache ~= nil then state.cached[key] = coverCache end
	end
	if coverCache ~= nil then state.usedCovers[coverCache] = true end

	dropUnsendableTags(info)
	state.tracks += 1
	return state.events:push({
		type = "track",
		info = info,
		entry = fileEntry,
		cover = entry.cover,
		coverCache = coverCache
	})
end

---@param state beat.InspectorState
---@param entries beat.ScanEntry[]
---@return boolean finished # False when a push closed the channel: the scan was cancelled
local function walk(state, entries)
	local lastProgress = time.now()

	for _, entry in ipairs(entries) do
		-- A cancelled scan closes the channel the job reads and sends this shard one message.
		-- The check is between files, so a read already under way is finished rather than torn.
		if state.control:pop() ~= nil then return false end

		state.current = entry.path
		if not inspectOne(state, entry) then return false end
		state.inspected += 1

		local now = time.now()
		if state.inspected % PROGRESS_EVERY == 0 or now - lastProgress >= PROGRESS_SECONDS then
			local sent = state.events:push({
				type = "progress",
				worker = state.index,
				inspected = state.inspected,
				tracks = state.tracks,
				skipped = state.skipped,
				current = clean(state.current)
			})
			if not sent then return false end
			lastProgress = now
		end
	end

	return true
end

--- Inspects a shard and pushes every track through the channel the coordinator reads.
---
--- This is the whole of a scan inspector thread; `beat.app.services.scan.job` starts it and never
--- touches its tables again. `known` is keyed by path and holds the records the library says it
--- already read.
---@param entries beat.ScanEntry[]
---@param known table<string, table>
---@param root string
---@param eventsAddress string
---@param controlAddress string
---@param index number
function Inspect.run(entries, known, root, eventsAddress, controlAddress, index)
	local events = threading.channelFromAddress(eventsAddress)
	local control = threading.channelFromAddress(controlAddress)
	---@type beat.InspectorState
	local state = {
		events = events,
		control = control,
		index = index,
		root = root,
		known = known,
		cached = {},
		triedFolder = {},
		usedCovers = {},
		inspected = 0,
		tracks = 0,
		skipped = 0,
		errors = {},
		current = nil
	}

	local ok, finished = pcall(walk, state, entries)

	if not ok then
		events:push({ type = "error", worker = index, message = clean(finished) })
	elseif finished then
		local covers = {}
		for cover in pairs(state.usedCovers) do covers[#covers + 1] = cover end
		events:push({
			type = "done",
			worker = index,
			inspected = state.inspected,
			tracks = state.tracks,
			skipped = state.skipped,
			errors = state.errors,
			covers = covers
		})
	end

	-- The job holds both channels until this thread has been joined, so what is given back here is
	-- this state's own reference.
	events:close()
	control:close()
end

return Inspect
