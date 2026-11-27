-- The last scanned library, kept so a launch can draw the songs it already knows before (or
-- instead of) walking the folder again. Only the fields a Track is made from are written: a scan
-- can rebuild every index and album from them, and a picture is still read from the file itself
-- when a cover is first requested.
local fs = require("fs")
local json = require("json")
local buffer = require("string.buffer")
local path = require("path")
local threading = require("threading")
local time = require("wonderland.time")
local paths = require("beat.paths")
local Library = require("beat.music.library")
local Log = require("beat.log")

local LibraryCache = {}

-- Raised when what a scan reads changes, so a cache written by an older scan is read again rather
-- than trusted: 7 files a track with no album tag as a single of its own, where 6 named it after
-- its folder. 6 added each track's audio fingerprint, which the listener's tags are keyed by, and
-- a cache written before it has none, so every track must be read once to get one. 5 was treble's
-- exact length for an MP3 with no length header, where 4 had a guess.
local VERSION = 7

-- The version before it, which is still read when it will group every track the way 7 does; see
-- `sameGrouping`. A full re-inspect is a long walk of a remote folder, so a cache that already
-- says the right things is not thrown away over the number in its header.
local PREVIOUS = 6

--- Whether a 6 cache recorded a track the way 7 would group it. 6 named a file with no album tag
--- after its folder, and a file with no artist tag after its folder's parent, while 7 makes the
--- first a single named after its own title and calls the second an unknown artist; both wrote
--- the same album, key and artist for a file whose tags named them. A record whose album is its
--- folder's name, or whose artist is its folder's parent's name, may be either, and nothing in
--- the record says which, so it is left out of what the cache loads and read again instead.
---@param record table
---@return boolean
local function sameGrouping(record)
	local dir = path.dirname(record.path)
	return record.album ~= path.basename(dir) and record.artist ~= path.basename(path.dirname(dir))
end

local function cacheFile()
	return paths.file("library.json")
end

--- Fills `record` with one track, reusing tables that are already there: a save packs every track
--- into the same scratch table so a large library does not build a second full copy of itself.
--- Every field is assigned each time, so a value a previous track wrote is gone when this one does
--- not have one.
---@param record json.Object
---@param track beat.Track
---@param key string? # The album the scan put it in, which its tags alone do not always say
local function packInto(record, track, key)
	record.path = track.path
	record.key = key
	record.title = track.title
	record.artist = track.artist
	record.album = track.album
	record.albumArtist = track.albumArtist
	record.number = track.number
	record.disc = track.disc
	record.year = track.year
	record.genre = track.genre
	record.duration = track.duration
	record.format = track.format
	record.sampleRate = track.sampleRate
	record.channels = track.channels
	record.hasPicture = track.hasPicture
	record.coverPath = track.coverPath
	record.coverCache = track.coverCache
	record.modified = track.modified
	record.fingerprint = track.fingerprint
	return record
end

--- One track as a cache record: only the fields a Track is made from, plus the album key the scan
--- filed it under. A scan also writes these for the library already loaded, so an inspector can
--- take a file it has not touched from one instead of reading it again.
---@param track beat.Track
---@param key string? # The album the scan put it in, which its tags alone do not always say
---@return table
function LibraryCache.pack(track, key)
	return packInto({}, track, key)
end

-- Records are batched into strings of this many bytes before a write: one write per track is a
-- syscall per track, while one string for the whole library is the copy a save is avoiding.
local CHUNK = 64 * 1024

---@class beat.LibraryCacheWriter
---@field library beat.Library
---@field file string
---@field tmp string
---@field out file*
---@field batch string.buffer
---@field record json.Object
---@field index number # The next track to pack
---@field first boolean # Whether the next record is the first in the array
---@field finished boolean
---@field failed string?

local Writer = {}
Writer.__index = Writer

--- Gives up on a save in progress: closes the temp file and removes it, so a cancelled write
--- leaves the previous cache exactly as it was.
---@param self beat.LibraryCacheWriter
---@param message string
function Writer:fail(message)
	if self.finished then return end
	self.finished = true
	self.failed = message
	local out = self.out
	self.out = nil
	if out ~= nil then pcall(out.close, out) end
	fs.delete(self.tmp)
	Log.write("error", "library cache could not be written to " .. self.file)
end

--- Drops a save that will never be read: closes the temp file, removes it, and leaves the cache
--- the last completed save wrote exactly where it was.
---@param self beat.LibraryCacheWriter
function Writer:abort()
	if self.finished then return end
	self.finished = true
	self.failed = "cancelled"
	local out = self.out
	self.out = nil
	if out ~= nil then pcall(out.close, out) end
	fs.delete(self.tmp)
end

--- Packs and writes tracks until the budget is spent. Answers "more" when there are tracks left,
--- "done" once the temp file is closed and renamed over the cache, and "failed" when a write or
--- an encode did not work. `budget` is in seconds: a save on the tick that finishes a scan takes
--- a few milliseconds rather than the whole library in one.
---@param self beat.LibraryCacheWriter
---@param budget number?
---@return "more"|"done"|"failed"
---@return string? err
function Writer:step(budget)
	if self.finished then
		if self.failed ~= nil then return "failed", self.failed end
		return "done"
	end

	local clock = time.now
	local deadline = clock() + (budget or math.huge)
	local library = self.library
	local tracks = library.tracks
	local count = #tracks
	local batch, record = self.batch, self.record
	local out = self.out
	---@cast out file*
	local at = self.index

	while at <= count do
		local track = tracks[at]
		local album = library:album(track.albumId)
		packInto(record, track, album?.key)
		local ok, encoded = pcall(json.encode, record)
		if not ok then
			self:fail(tostring(encoded))
			return "failed", self.failed
		end
		---@cast encoded string
		if self.first then
			self.first = false
		else
			batch:put(",")
		end
		batch:put(encoded)
		if #batch >= CHUNK then
			local chunk = batch:get()
			if not out:write(chunk) then
				self:fail("library cache write failed")
				return "failed", self.failed
			end
		end
		at += 1
		if clock() >= deadline then break end
	end

	self.index = at
	if at <= count then return "more" end

	-- The last partial batch and the closing bracket, then the rename that makes it the cache.
	local tail = batch:get()
	if #tail > 0 and not out:write(tail) then
		self:fail("library cache write failed")
		return "failed", self.failed
	end
	if not out:write("]}") then
		self:fail("library cache write failed")
		return "failed", self.failed
	end
	self.out = nil
	if not out:close() then
		self:fail("library cache write failed")
		return "failed", self.failed
	end

	local moved, moveErr = fs.move(self.tmp, self.file)
	if not moved then
		fs.delete(self.tmp)
		self.finished = true
		self.failed = tostring(moveErr)
		Log.write("error", "library cache could not be written to " .. self.file)
		return "failed", self.failed
	end

	self.finished = true
	return "done"
end

--- The cache a scan is about to replace, opened for writing a slice at a time: the temp file is
--- created and the header written here, and `step` fills it. A nil answer is a save that could
--- not even start, such as a cache directory that cannot be made or a disk that refuses the file.
---@param library beat.Library
---@return beat.LibraryCacheWriter? writer
---@return string? err
function LibraryCache.openSave(library)
	local folder = paths.directory()
	if not fs.isdir(folder) then
		fs.mkdirAll(folder)
		if not fs.isdir(folder) then return nil, "cannot create " .. folder end
	end

	local file = cacheFile()
	local tmp = file .. ".tmp"
	local out, openErr = io.open(tmp, "wb")
	if not out then
		Log.write("error", "library cache could not be written to " .. file)
		return nil, openErr
	end

	local rootOk, encodedRoot = pcall(json.encode, library.root)
	if not rootOk then
		out:close()
		fs.delete(tmp)
		Log.write("error", "library cache could not be written to " .. file)
		return nil, tostring(encodedRoot)
	end

	local header = '{"version":' .. tostring(VERSION) .. ',"root":' .. encodedRoot .. ',"tracks":['
	if not out:write(header) then
		out:close()
		fs.delete(tmp)
		Log.write("error", "library cache could not be written to " .. file)
		return nil, "library cache write failed"
	end

	return setmetatable({
		library = library,
		file = file,
		tmp = tmp,
		out = out,
		batch = buffer.new(CHUNK),
		record = {},
		index = 1,
		first = true,
		finished = false,
		failed = nil
	}, Writer)
end

--- Writes the cache a track at a time, into a temp file renamed over the old one once it is
--- complete, so a crash or a full disk leaves the previous cache readable. Nothing holds the whole
--- library twice: one scratch record is encoded at a time and a bounded batch is written out.
--- The blocking form of `openSave`/`step`, for a caller that cannot wait across ticks.
---@param library beat.Library
---@return boolean
---@return string? err
function LibraryCache.save(library)
	local writer, openErr = LibraryCache.openSave(library)
	if writer == nil then return false, openErr end

	while true do
		local status, stepErr = writer:step(math.huge)
		if status == "done" then return true end
		if status == "failed" then return false, stepErr end
	end
end

--- A field of a decoded value, or nil when the document does not have it. `json.Value:get` raises
--- for a missing key unless it is given a default, and a default of nil means "no default".
local MISSING = {}

---@param value json.Value
---@param key string
---@return any
local function field(value, key)
	local got = value:get(key, MISSING)
	if got == MISSING then return nil end
	---@cast got json.Value
	return got:val()
end

--- The track records a decoded cache holds for this root, or nothing for one written for another
--- root or version. The header is checked once here so that the two ways the records are taken --
--- into a Library built on this thread, or a batch at a time out of a loading thread -- agree
--- about what they will read.
---@param decoded json.Value
---@param root string
---@return json.Value? tracks
---@return number? version
local function tracksOf(decoded, root)
	if decoded:type() ~= "object" or field(decoded, "root") ~= root then return nil end

	local version = field(decoded, "version")
	if version ~= VERSION and version ~= PREVIOUS then return nil end

	local tracks = decoded:get("tracks", MISSING)
	if tracks == MISSING then return nil end
	---@cast tracks json.Value
	if not (tracks:is("array") or tracks:is("object")) then return nil end

	return tracks, version
end

--- The library a decoded cache says, or nothing for one written for another root or version.
--- A 6 cache is read when it groups tracks the way 7 does; the records it may have named after
--- their folder are returned instead, for the scan to read again.
---@param decoded json.Value
---@param root string
---@return beat.Library? library
---@return string[]? outdated
local function read(decoded, root)
	local tracks, version = tracksOf(decoded, root)
	if tracks == nil or version == nil then return nil end

	local outdated = nil
	local library = Library.new(root)
	for _, item in tracks:children() do
		if item == nil or not item:is("object") then return nil end
		local record = item:unpack()
		---@cast record table
		if type(record.path) ~= "string" then return nil end
		if version == PREVIOUS and not sameGrouping(record) then
			outdated = outdated or {}
			outdated[#outdated + 1] = record.path
		else
			library:addCached(record)
		end
	end
	library:finish()

	return library, outdated
end

--- Where the cache file is. A thread cannot be handed the function `paths.directory` overrides,
--- so the caller that starts a read passes this string instead.
---@return string
function LibraryCache.file()
	return cacheFile()
end

--- The `json` module that can read a document. A thread started under `lde run` begins with
--- lde's own tool bundle in `package.preload`, and the `json` there is not the app's: it has no
--- `Document`. The app's module is on `package.path` in a source run, so it is required again
--- with the preloaded one out of the way; a compiled program carries the app's modules in its
--- preload and this returns them as they are.
---@return table
local function documentJson()
	local found = require("json")
	if found.Document ~= nil then return found end

	local preloaded = package.preload["json"]
	package.preload["json"] = nil
	package.loaded["json"] = nil
	local ok, appJson = pcall(require, "json")
	if ok and appJson.Document ~= nil then return appJson end

	package.preload["json"] = preloaded
	package.loaded["json"] = found
	return found
end

--- Reads the cache on a thread and pushes its records through a channel, a batch at a time, for
--- the app to take into a library across frames. Nothing of the parsed document or the records
--- crosses back whole: each message is copied when it is pushed, so a large library never makes
--- one frame decode all of it, and the document is freed before the messages are read.
---
--- This is the body of the loading thread; the caller that started it keeps the other end of the
--- channel. `missing`, `error` and `rejected` say why no records follow, and `done` is always the
--- last message of a cache that was read.
---@param file string
---@param root string
---@param eventsAddress string
---@param batch number # Records one message carries
function LibraryCache.pour(file, root, eventsAddress, batch)
	local events = threading.channelFromAddress(eventsAddress)

	---@param kind string
	---@param message string?
	local function stop(kind, message)
		events:push({ kind = kind, message = message })
		events:close()
	end

	if not fs.isfile(file) then return stop("missing") end

	local jsonModule = documentJson()
	local ok, document = pcall(jsonModule.Document.open, file)
	if not ok then
		Log.write("error", "library cache could not be read: " .. tostring(document))
		return stop("error", tostring(document))
	end

	---@cast document json.Document
	local decoded = document:root()
	local tracks, version = tracksOf(decoded, root)
	if tracks == nil or version == nil then
		document:free()
		return stop("rejected")
	end

	local records, count = {}, 0
	local outdated = nil
	for _, item in tracks:children() do
		if item == nil or not item:is("object") then
			document:free()
			return stop("rejected")
		end
		local record = item:unpack()
		---@cast record table
		if type(record.path) ~= "string" then
			document:free()
			return stop("rejected")
		end
		if version == PREVIOUS and not sameGrouping(record) then
			outdated = outdated or {}
			outdated[#outdated + 1] = record.path
		else
			count += 1
			records[count] = record
			if count >= batch then
				if not events:push({ kind = "records", records = records }) then
					document:free()
					events:close()
					return
				end
				records, count = {}, 0
			end
		end
	end
	document:free()

	if count > 0 and not events:push({ kind = "records", records = records }) then
		events:close()
		return
	end
	events:push({ kind = "done", outdated = outdated })
	events:close()
end

--- Reads the cache back into a library. The file is parsed by yyjson outside the Lua heap, and
--- each record is unpacked one at a time, so the read never holds a full Lua copy of the
--- decoded document and the library at once, and only the library outlives the read. The parsed
--- document is freed as soon as the records are in: left to its finalizer it is several MiB of
--- the process held until the collector happens to come round to it.
---@param root string
---@return beat.Library?
---@return string[]? outdated # Tracks an older cache may have grouped by folder, to read again
function LibraryCache.load(root)
	local file = cacheFile()
	if not fs.isfile(file) then return nil end

	local ok, document = pcall(json.Document.open, file)
	if not ok then
		Log.write("error", "library cache could not be read: " .. tostring(document))
		return nil
	end

	---@cast document json.Document
	local library, outdated = read(document:root(), root)
	document:free()
	return library, outdated
end

return LibraryCache
