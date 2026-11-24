-- The scan: first the tree, then the files.
--
-- Pass one is directory metadata only -- `readdir` with the type a directory entry already says,
-- so no file is opened and no `stat` is made. It gives an exact file count and a cover candidate
-- per folder. Pass two opens each audio file once and reads its header with `treble.audio.inspect`;
-- no decoder, no audio data and no picture is read. The work is sliced by wall clock so a large
-- folder never blocks a frame.
local fs = require("fs")
local path = require("path")
local names = require("beat.music.names")
local Library = require("beat.music.library")
local audio = require("treble.audio")

local AUDIO = { flac = true, mp3 = true, opus = true, ogg = true, wav = true, m4a = true }

local IMAGES = { jpg = true, jpeg = true, png = true, gif = true, bmp = true }

local COVER_NAMES = { cover = true, folder = true, front = true, album = true }

local JUNK = { ["@eaDir"] = true, ["#recycle"] = true, ["System Volume Information"] = true, ["$RECYCLE.BIN"] = true }

---@class beat.ScanProgress
---@field phase "enumerate"|"inspect"|"done"|"cancelled"
---@field files number
---@field inspected number
---@field tracks number
---@field skipped number
---@field errors { path: string, message: string }[]
---@field current string?

---@class beat.Scanner
---@field root string
---@field library beat.Library? # Built only when the caller wants the rows as well as the events
---@field phase "enumerate"|"inspect"|"done"|"cancelled"
---@field files string[] # Paths, with the rest of the entry made when it is inspected
---@field entryIndex number # The next file `takeEntries` hands over
---@field trackCount number
---@field dirs string[]
---@field dirIndex number
---@field pendingDir string? # The directory whose entries are being pulled, if any
---@field pendingIterator (fun(): fs.DirEntry?)? # Its reader, kept between slices
---@field pendingCover string? # The folder picture found so far in it
---@field fileIndex number
---@field dirCovers table<string, string>
---@field skipped number
---@field errors { path: string, message: string }[]
---@field current string?
---@field version number
---@field onTrack fun(info: treble.audio.Inspect, entry: { path: string, dir: string, name: string, ext: string, modifyTime: number? }, cover: string?)?
local Scanner = {}
Scanner.__index = Scanner

---@param root string
---@param opts { library: boolean? }? # `library = false` is the scan job: it builds its own rows, not a second copy
---@return beat.Scanner
function Scanner.new(root, opts)
	local normalized = path.normalize(root)
	local keepLibrary = opts == nil or opts.library ~= false

	return setmetatable(
		{
			root = normalized,
			library = keepLibrary ? Library.new(normalized) : nil,
			phase = "enumerate",
			files = {},
			entryIndex = 1,
			trackCount = 0,
			dirs = { normalized },
			dirIndex = 1,
			pendingDir = nil,
			pendingIterator = nil,
			pendingCover = nil,
			fileIndex = 1,
			dirCovers = {},
			skipped = 0,
			errors = {},
			current = nil,
			version = 0
		},
		Scanner
	)
end

---@param entry string
---@return boolean
local function isJunk(entry)
	return JUNK[entry] == true or entry:sub(1, 1) == "."
end

---@param name string
local function extensionOf(name)
	local ext = name:match("%.([^%.]+)$")
	if ext == nil then return nil end
	return ext:lower()
end

---@param dir string
---@param name string
local function entryType(dir, name)
	local entry = fs.stat(path.join(dir, name))
	if entry == nil then return "unknown" end
	return entry.type or "unknown"
end

-- Entries pulled from one directory per slice. A folder with thousands of files would otherwise
-- be one step that takes longer than the frame it shares, and this library has such folders.
local ENTRY_BATCH = 64

--- One directory entry into the walk's lists, answering the folder picture found so far.
---@param self beat.Scanner
---@param dir string
---@param name string
---@param kind string
---@param cover string?
---@return string? cover
local function takeEntry(self, dir, name, kind, cover)
	if kind == "dir" then
		self.dirs[#self.dirs + 1] = path.join(dir, name)
	elseif kind == "file" then
		local ext = extensionOf(name)
		if ext ~= nil and AUDIO[ext] then
			self.files[#self.files + 1] = path.join(dir, name)
		elseif ext ~= nil and IMAGES[ext] then
			local base = names.stripExtension(name):lower()
			if COVER_NAMES[base] and cover == nil then
				cover = path.join(dir, name)
			end
		end
	end

	return cover
end

--- Pulls the next slice of one directory, or opens the next one. The reader stays open between
--- slices, so a directory of thousands of entries is walked over as many steps as it needs rather
--- than one step that holds the frame.
---@param self beat.Scanner
local function enumerateOne(self)
	local dir = self.pendingDir
	if dir == nil then
		dir = self.dirs[self.dirIndex]
		self.dirIndex += 1

		if dir == nil then
			self.phase = "inspect"
			self.current = nil
			return
		end

		local iterator = fs.readdir(dir)
		if iterator == nil then
			self.skipped += 1
			if #self.errors < 100 then
				self.errors[#self.errors + 1] = { path = dir, message = "cannot read folder" }
			end
			return
		end

		self.pendingDir = dir
		self.pendingIterator = iterator
		self.current = dir
	end

	---@cast dir -nil
	local iterator = self.pendingIterator
	---@cast iterator -nil
	local cover = self.pendingCover

	for _ = 1, ENTRY_BATCH do
		local entry = iterator()
		if entry == nil then
			if cover ~= nil then self.dirCovers[dir] = cover end
			self.pendingDir = nil
			self.pendingIterator = nil
			self.pendingCover = nil
			self.version += 1
			return
		end

		local name = entry.name
		if not isJunk(name) then
			local kind = entry.type
			if kind == "unknown" then kind = entryType(dir, name) end
			cover = takeEntry(self, dir, name, kind, cover)
		end
	end

	self.pendingCover = cover
	self.version += 1
end

---@param self beat.Scanner
local function inspectOne(self)
	local entry = self.files[self.fileIndex]
	if entry == nil then
		self.phase = "done"
		self.current = nil
		if self.library ~= nil then self.library:finish() end
		self.version += 1
		return
	end

	self.fileIndex += 1
	self.current = entry

	local dir = path.dirname(entry)
	local name = path.basename(entry)
	local ext = extensionOf(name) or ""
	local stat = fs.stat(entry)
	local fileEntry = { path = entry, dir = dir, name = name, ext = ext, modifyTime = stat?.modifyTime }

	local ok, info = pcall(audio.inspect, entry)
	if not ok or info == nil then
		self.skipped += 1
		if #self.errors < 100 then
			self.errors[#self.errors + 1] = {
				path = entry,
				message = ok ? "not an audio file this library reads" : tostring(info)
			}
		end
	else
		local cover = self.dirCovers[dir]
		if self.library ~= nil then self.library:add(info, fileEntry, cover) end
		self.trackCount += 1
		if self.onTrack ~= nil then self.onTrack(info, fileEntry, cover) end
	end

	self.version += 1
end

--- Runs work until the wall-clock budget is spent. Returns whether anything changed.
---@param budget number # seconds
---@param now fun(): number # monotonic seconds; the caller owns the clock
---@return boolean
function Scanner:step(budget, now)
	if self.phase == "done" or self.phase == "cancelled" then return false end

	local clock = now or os.clock
	local deadline = clock() + budget
	local changed = false

	while clock() < deadline do
		local before = self.version

		if self.phase == "enumerate" then
			enumerateOne(self)
		elseif self.phase == "inspect" then
			inspectOne(self)
		end

		if self.version ~= before then changed = true end

		if self.phase == "done" or self.phase == "cancelled" then break end
	end

	return changed
end

--- Run only the directory walk, never the inspection pass. A parallel scan uses this to get a
--- complete file list before handing shards to the scan job's inspector threads.
---@param budget number # seconds
---@param now fun(): number # monotonic seconds; the caller owns the clock
---@return boolean changed
function Scanner:enumerateStep(budget, now)
	if self.phase ~= "enumerate" then return false end

	local clock = now or os.clock
	local deadline = clock() + budget
	local changed = false

	while self.phase == "enumerate" and clock() < deadline do
		local before = self.version
		enumerateOne(self)
		if self.version ~= before then changed = true end
	end

	return changed
end

---@class beat.ScanEntry
---@field path string
---@field dir string
---@field name string
---@field ext string
---@field cover string?

--- What the directory walk found, ready for an inspector. The folder cover is carried here so
--- the inspector does not have to read the directory again.
---@return beat.ScanEntry[]
function Scanner:entries()
	local entries = {}
	for _, file in ipairs(self.files) do
		local dir = path.dirname(file)
		local name = path.basename(file)
		entries[#entries + 1] = {
			path = file,
			dir = dir,
			name = name,
			ext = extensionOf(name) or "",
			cover = self.dirCovers[dir]
		}
	end

	return entries
end

--- The next entries in the walk's list, at most `count`, for a caller that would rather not build
--- a large library's whole manifest in one frame. `entries()` answers all of them at once.
---@param count number
---@return beat.ScanEntry[]
function Scanner:takeEntries(count)
	local entries = {}
	local files = self.files
	local last = math.min(#files, self.entryIndex + count - 1)

	for at = self.entryIndex, last do
		local file = files[at]
		local dir = path.dirname(file)
		local name = path.basename(file)
		entries[#entries + 1] = {
			path = file,
			dir = dir,
			name = name,
			ext = extensionOf(name) or "",
			cover = self.dirCovers[dir]
		}
	end

	self.entryIndex = last + 1
	return entries
end

---@return beat.ScanProgress
function Scanner:progress()
	return {
		phase = self.phase,
		files = #self.files,
		inspected = math.min(self.fileIndex - 1, #self.files),
		tracks = self.trackCount,
		skipped = self.skipped,
		errors = self.errors,
		current = self.current
	}
end

function Scanner:cancel()
	-- The directory being walked is read to its end so its handle is closed: a scan that stops
	-- between slices would otherwise keep the folder open until the process ends.
	local iterator = self.pendingIterator
	if iterator ~= nil then
		while iterator() ~= nil do end
		self.pendingIterator = nil
		self.pendingDir = nil
		self.pendingCover = nil
	end

	self.phase = "cancelled"
	self.current = nil
end

---@return boolean
function Scanner:isDone()
	return self.phase == "done" or self.phase == "cancelled"
end

return Scanner
