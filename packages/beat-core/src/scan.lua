-- The scan: first the tree, then the files.
--
-- Pass one is directory metadata only -- `readdir` with the type a directory entry already says,
-- so no file is opened and no `stat` is made. It gives an exact file count and a cover candidate
-- per folder. Pass two opens each audio file once and reads its header with `treble.audio.inspect`;
-- no decoder, no audio data and no picture is read. The work is sliced by wall clock so a large
-- folder never blocks a frame.
local fs = require("fs")
local path = require("path")
local util = require("beat-core.util")
local Library = require("beat-core.library")
local audio = require("treble.audio")

local AUDIO = {
flac = true,
mp3 = true,
opus = true,
ogg = true,
wav = true,
}

local IMAGES = {
jpg = true,
jpeg = true,
png = true,
gif = true,
bmp = true,
}

local COVER_NAMES = {
cover = true,
folder = true,
front = true,
album = true,
}

local JUNK = {
["@eaDir"] = true,
["#recycle"] = true,
["System Volume Information"] = true,
["$RECYCLE.BIN"] = true,
}

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
---@field trackCount number
---@field dirs string[]
---@field dirIndex number
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
---@param opts { library: boolean? }? # `library = false` is the worker: it emits rows, not a second copy
---@return beat.Scanner
function Scanner.new(root, opts)
	local normalized = path.normalize(root)
	local keepLibrary = opts == nil or opts.library ~= false

	return setmetatable({
	root = normalized,
	library = keepLibrary and Library.new(normalized) or nil,
	phase = "enumerate",
	files = {},
	trackCount = 0,
	dirs = { normalized},
	dirIndex = 1,
	fileIndex = 1,
	dirCovers = {},
	skipped = 0,
	errors = {},
	current = nil,
	version = 0,
	}, Scanner)
end

---@param entry string
---@return boolean
local function isJunk(entry)
	return JUNK[entry] == true or entry:sub(1, 1) == "."
end

---@param name string
---@return string?
local function extensionOf(name)
	local ext = name:match("%.([^%.]+)$")
	if ext == nil then return nil end
	return ext:lower()
end

---@param dir string
---@param name string
---@return string
local function entryType(dir, name)
	local entry = fs.stat(path.join(dir, name))
	if entry == nil then return "unknown" end
	return entry.type or "unknown"
end

---@param self beat.Scanner
local function enumerateOne(self)
	local dir = self.dirs[self.dirIndex]
	self.dirIndex = self.dirIndex + 1

	if dir == nil then
		self.phase = "inspect"
		self.current = nil
		return
	end

	local iterator = fs.readdir(dir)
	if iterator == nil then
		self.skipped = self.skipped + 1
		if #self.errors < 100 then
			self.errors[#self.errors + 1] = { path = dir, message = "cannot read folder"}
		end
		return
	end

	local cover = nil
	local names = {}

	for entry in iterator do
			names[#names + 1] = entry
		end

	for _, entry in ipairs(names) do
			local name = entry.name
			if not isJunk(name) then
				local kind = entry.type
				if kind == "unknown" then kind = entryType(dir, name) end

				if kind == "dir" then
					self.dirs[#self.dirs + 1] = path.join(dir, name)
				elseif kind == "file" then
					local ext = extensionOf(name)
					if ext ~= nil and AUDIO[ext] then
						self.files[#self.files + 1] = path.join(dir, name)
					elseif ext ~= nil and IMAGES[ext] then
						local base = util.stripExtension(name):lower()
						if COVER_NAMES[base] and cover == nil then
							cover = path.join(dir, name)
						end
					end
				end
			end
		end

	if cover ~= nil then self.dirCovers[dir] = cover end
	self.current = dir
	self.version = self.version + 1
end

---@param self beat.Scanner
local function inspectOne(self)
	local entry = self.files[self.fileIndex]
	if entry == nil then
		self.phase = "done"
		self.current = nil
		if self.library ~= nil then self.library:finish() end
		self.version = self.version + 1
		return
	end

	self.fileIndex = self.fileIndex + 1
	self.current = entry

	local dir = path.dirname(entry)
	local name = path.basename(entry)
	local ext = extensionOf(name) or ""
	local stat = fs.stat(entry)
	local fileEntry = {
	path = entry,
	dir = dir,
	name = name,
	ext = ext,
	modifyTime = stat and stat.modifyTime or nil,
	}

	local ok, info = pcall(audio.inspect, entry)
	if not ok or info == nil then
		self.skipped = self.skipped + 1
		if #self.errors < 100 then
			self.errors[#self.errors + 1] = {
			path = entry,
			message = ok and "not an audio file this library reads" or tostring(info),
			}
		end
	else
		local cover = self.dirCovers[dir]
		if self.library ~= nil then self.library:add(info, fileEntry, cover) end
		self.trackCount = self.trackCount + 1
		if self.onTrack ~= nil then self.onTrack(info, fileEntry, cover) end
	end

	self.version = self.version + 1
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
--- complete file list before handing shards to inspector processes.
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
			cover = self.dirCovers[dir],
			}
		end

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
	current = self.current,
	}
end

function Scanner:cancel()
	self.phase = "cancelled"
	self.current = nil
end

---@return boolean
function Scanner:isDone()
	return self.phase == "done" or self.phase == "cancelled"
end

return Scanner
