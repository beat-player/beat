-- A track read and decoded on a thread of its own, so the audio thread never waits on a disk.
--
-- treble's sources read synchronously: a slow network mount turns `source:read` into a sleep, and
-- the thread calling it cannot feed the device meanwhile. A prefetch source keeps a ring of decoded
-- PCM about two and a half seconds long, filled by a reader thread; treble's `read` only copies
-- from that ring, which is memory work. A read that takes half a second then costs nothing audible:
-- the ring already holds more than that. The device buffer stays as small as it was, so pause,
-- seek and track changes still flush and answer at once.
--
-- The reader owns the ring it allocated, so it is the reader that frees it when it stops; the app
-- side only ever maps the address. Counters cross as channel messages, which is also what makes
-- the writes visible: the reader pushes after writing, the audio side pops before reading.
local ffi = require("ffi")
local threading = require("threading")
local treble = require("treble")
local native = require("threading.native")

-- The decoded audio kept ahead of the device. More than a network mount's read should ever take;
-- the reader stops filling here and waits for the audio side to drain.
local READ_AHEAD_SECONDS = 2.5

-- How long a state that must wait for the reader sleeps before looking for messages again.
local WAIT_MS = 50

---@class beat.PrefetchLib
---@field threading_alloc fun(size: number): ffi.cdata*
---@field threading_free fun(pointer: ffi.cdata*)

---@type beat.PrefetchLib
local lib = native.lib --[[@as beat.PrefetchLib]]

local Prefetch = {}

--- A pointer as the eight raw bytes another thread reads back as a pointer: Android tags heap
--- pointers on arm64, so an address is above 2^53 and a double would round it somewhere else.
---@param pointer ffi.cdata*
local function encode(pointer)
	return ffi.string(ffi.new("void*[1]", pointer), ffi.sizeof("void*"))
end

---@param address string
---@return ffi.cdata* pointer
local function decode(address)
	return ffi.cast("void* const*", address)[0]
end

-- Readers a track change asked to stop before they were done; a reader can be inside a 500 ms read,
-- and joining it would hold the audio thread. They are joined on a later pass once they finish.
---@class beat.PrefetchClosing
---@field handle threading.Handle
---@field commands threading.Channel?
---@field events threading.Channel?

---@class beat.PrefetchStopped
---@field records beat.PrefetchClosing[]
---@type beat.PrefetchStopped
local stopped = { records = {} }

--- Joins the readers that have finished since the last look. Cheap when there are none.
function Prefetch.reap()
	local records = stopped.records
	for at = #records, 1, -1 do
		local record = records[at]
		if record.handle:done() then
			pcall(record.handle.join, record.handle)
			-- The reader has attached and gone; only now can the channels lose this side's refs.
			local commands = record.commands
			if commands ~= nil then commands:close() end
			local events = record.events
			if events ~= nil then events:close() end
			table.remove(records, at)
		end
	end
end

---@param length number
---@param channels number
local function copyToRing(ring, length, channels, at, source, frames)
	local first = math.min(frames, length - at)
	ffi.copy(ring + at * channels, source, first * channels * 2)
	if first < frames then
		ffi.copy(ring, source + first * channels, (frames - first) * channels * 2)
	end
end

--- Waits for the readers in `stopped` to finish, joining them. A teardown that can afford to wait
--- a moment uses this so a test process does not leave Lua states behind; playback never does.
---@param milliseconds number
---@return boolean allFinished
function Prefetch.waitStopped(milliseconds)
	local tries = math.max(1, math.floor(milliseconds / 5))
	for _ = 1, tries do
		Prefetch.reap()
		if #stopped.records == 0 then return true end
		threading.sleep(5)
	end
	return #stopped.records == 0
end

--- What runs in the reader's own Lua state. It opens the path, decodes into the ring it allocated,
--- and follows seek/quit commands until it is asked to stop.
---@param path string
---@param commandAddress string
---@param eventAddress string
---@param startFrame number
function Prefetch.run(path, commandAddress, eventAddress, startFrame)
	local commands = threading.channelFromAddress(commandAddress)
	local events = threading.channelFromAddress(eventAddress)

	local source, err = treble.Audio.fromPath(path)
	if source == nil then
		events:push({ kind = "error", message = err or "the audio file could not be opened" })
		commands:wait(WAIT_MS)
		commands:close()
		events:close()
		return
	end

	local channels = source.channels
	local rate = source.sampleRate
	local frameCount = source.frameCount
	local capacity = math.max(1024, math.floor(rate * READ_AHEAD_SECONDS))
	local ring = ffi.cast("int16_t*", lib.threading_alloc(capacity * channels * ffi.sizeof("int16_t")))
	if ring == nil then
		source:close()
		events:push({ kind = "error", message = "not enough memory to read ahead" })
		commands:wait(WAIT_MS)
		commands:close()
		events:close()
		return
	end

	-- A second per read, even at a high rate: one slow read then buys a second of audio, which is
	-- what lets a mount that takes half a second per read still keep ahead of the device. The ring
	-- bounds the chunk when there is less room than that.
	local chunkFrames = math.max(8192, rate)
	local scratch = ffi.new("int16_t[?]", chunkFrames * channels)
	local generation = 0
	local writeFrame = startFrame
	if startFrame > 0 and not source:seek(startFrame) then
		events:push({ kind = "error", message = "the audio file could not be seeked" })
	end

	events:push({
		kind = "ready",
		address = encode(ring),
		capacity = capacity,
		sampleRate = rate,
		channels = channels,
		frameCount = frameCount,
		generation = generation
	})

	local consumed = startFrame
	local stoppedReading = false
	local quit = false

	while not quit do
		while true do
			local command = commands:pop() --[[@as table?]]
			if command == nil then break end
			local kind = command.kind
			if kind == "quit" or kind == "release" then
				quit = true
				break
			elseif kind == "consumed" then
				consumed = command.read or consumed
			elseif kind == "seek" then
				generation = command.generation or generation
				writeFrame = command.frame or 0
				consumed = writeFrame
				source:seek(writeFrame)
				events:push({ kind = "reset", generation = generation, written = writeFrame })
				stoppedReading = false
			end
		end
		if quit then break end

		if stoppedReading then
			commands:wait(WAIT_MS)
		else
			local lead = writeFrame - consumed
			local room = math.min(capacity - lead, chunkFrames)
			if frameCount > 0 then room = math.min(room, frameCount - writeFrame) end

			if room <= 0 then
				if frameCount > 0 and writeFrame >= frameCount then
					events:push({ kind = "ended", generation = generation })
					stoppedReading = true
				else
					-- The ring is full: wait for the audio side to take some, or for a seek.
					commands:wait(WAIT_MS)
				end
			else
				local frames, readError = source:read(scratch, room)
				if frames == nil then
					events:push({ kind = "error", message = readError or "the audio file could not be read" })
					stoppedReading = true
				elseif frames == 0 then
					events:push({ kind = "ended", generation = generation })
					stoppedReading = true
				else
					copyToRing(ring, capacity, channels, writeFrame % capacity, scratch, frames)
					writeFrame += frames
					events:push({ kind = "buffered", generation = generation, written = writeFrame })
				end
			end
		end
	end

	-- The app is done with the ring before it sends release or quit; freeing it here means the
	-- memory belongs to the thread that filled it, and no Lua-side copy ever has to.
	source:close()
	lib.threading_free(ring)
	commands:close()
	events:close()
end

---@class beat.PrefetchSource
---@field path string
---@field sampleRate number
---@field channels number
---@field frameCount number
---@field commands threading.Channel?
---@field events threading.Channel?
---@field handle threading.Handle?
---@field ring ffi.cdata*? # int16[capacity * ringChannels]
---@field capacity number
---@field ringChannels number
---@field readPos number
---@field buffered number
---@field generation number
---@field ended boolean
---@field error string?
---@field closed boolean
---@field prefetched boolean
---@field startFrame number
local Source = {}
Source.__index = Source

---@param track { path: string, sampleRate: number?, channels: number?, frameCount: number? }
---@return beat.PrefetchSource
function Prefetch.new(track)
	return setmetatable({
		path = track.path,
		sampleRate = track.sampleRate or 0,
		channels = track.channels or 0,
		frameCount = track.frameCount or 0,
		commands = nil,
		events = nil,
		handle = nil,
		ring = nil,
		capacity = 0,
		ringChannels = 0,
		readPos = 0,
		buffered = 0,
		generation = 0,
		ended = false,
		error = nil,
		closed = false,
		prefetched = false,
		startFrame = 0
	}, Source)
end

--- Starts the reader and the ring it fills. Answers once the reader is running; with no metadata
--- to hand treble yet, it waits for the reader to report the file's own.
---@param waitForFormat boolean? # Wait for the reader's report even when the track had a rate
---@return boolean started
function Source:prefetch(waitForFormat)
	if self.prefetched or self.closed then return self.prefetched end

	local commands = threading.channel()
	local events = threading.channel()
	local commandAddress, eventAddress = commands:address(), events:address()
	local path, startFrame = self.path, self.startFrame

	local ok, handle = pcall(threading.spawn, function()
		require("beat.app.services.playback.prefetch").run(path, commandAddress, eventAddress, startFrame)
	end)
	if not ok then
		commands:close()
		events:close()
		self.error = tostring(handle)
		return false
	end

	self.commands = commands
	self.events = events
	self.handle = handle
	self.prefetched = true

	if waitForFormat or self.sampleRate <= 0 or self.channels <= 0 then
		while self.ring == nil and self.error == nil and not self:dead() do
			self:take(true)
		end
	end
	return self.error == nil and self.ring ~= nil
end

---@param handle threading.Handle
---@return boolean finished
function Source:joinIfDone(handle)
	if not handle:done() then return false end
	pcall(handle.join, handle)
	return true
end

---@return boolean dead
function Source:dead()
	local handle = self.handle
	if handle == nil then return false end
	if self:joinIfDone(handle) then
		self.handle = nil
		if self.error == nil and not self.ended then
			self.error = "the audio reader stopped"
		end
		return true
	end
	return false
end

--- Takes the reader's messages. With `block`, waits for one when none is queued.
---@param block boolean?
---@return boolean got
function Source:take(block)
	local events = self.events
	if events == nil then return false end

	local got = false
	for _ = 1, 256 do
		local event = events:pop() --[[@as table?]]
		if event == nil then break end
		got = true
		local kind = event.kind
		if kind == "ready" then
			local address = event.address
			if type(address) == "string" then self.ring = ffi.cast("int16_t*", decode(address)) end
			self.capacity = event.capacity or self.capacity
			self.ringChannels = event.channels or self.ringChannels
			if self.sampleRate <= 0 then self.sampleRate = event.sampleRate or 0 end
			if self.channels <= 0 then self.channels = event.channels or 0 end
			if self.frameCount <= 0 then self.frameCount = event.frameCount or 0 end
		elseif kind == "buffered" then
			if event.generation == self.generation and (event.written or 0) > self.buffered then
				self.buffered = event.written
			end
		elseif kind == "reset" then
			if event.generation == self.generation then
				self.buffered = event.written or self.readPos
				self.ended = false
			end
		elseif kind == "ended" then
			if event.generation == self.generation then self.ended = true end
		elseif kind == "error" then
			self.error = event.message or "the audio reader failed"
		end
	end

	if not got and block then
		events:wait(WAIT_MS)
		return true
	end
	return got
end

--- Copies decoded frames out, waiting only when the ring has none left. treble answers the number
--- of frames it got, and nil plus a message for a source that failed.
---@param out ffi.cdata*
---@param frames number
---@return number? frames
---@return string? err
function Source:read(out, frames)
	if self.closed then return 0 end

	while true do
		self:take(false)
		if self.error ~= nil then return nil, self.error end

		local ring = self.ring
		if ring ~= nil then
			local available = self.buffered - self.readPos
			if available > 0 then
				local channels = self.ringChannels
				local count = math.min(frames, available)
				local at = self.readPos % self.capacity
				local first = math.min(count, self.capacity - at)
				ffi.copy(out, ring + at * channels, first * channels * 2)
				if first < count then
					ffi.copy(out + first * channels, ring, (count - first) * channels * 2)
				end
				self.readPos += count
				local commands = self.commands
				if commands ~= nil then commands:push({ kind = "consumed", read = self.readPos }) end
				return count
			end
		end

		if self.ended then return 0 end
		if self:dead() then return nil, self.error or "the audio reader stopped" end
		self:take(true)
	end
end

--- Moves the reader to a frame without decoding the part before it. treble has already dropped
--- what the device held, so this answers at once; the first read after it may wait for the reader.
---@param frame number
---@return boolean
function Source:seek(frame)
	if self.closed then return false end
	self.generation += 1
	self.readPos = frame
	self.buffered = frame
	self.ended = false
	if self.commands ~= nil then
		self.commands:push({ kind = "seek", frame = frame, generation = self.generation })
	else
		self.startFrame = frame
	end
	return true
end

--- Stops the reader and gives the channels back. Never waits: a reader inside a network read would
--- hold the audio thread, so it is joined later by `Prefetch.reap`.
function Source:close()
	if self.closed then return end
	self.closed = true

	local commands, events, handle = self.commands, self.events, self.handle
	self.commands = nil
	self.events = nil
	self.handle = nil
	self.ring = nil

	if handle ~= nil then
		-- The reader may not have attached to the channels yet: a spawned function starts after
		-- anything this thread does next. Both ends' references are kept until the reader is done,
		-- or the channel could be freed while it is still reaching for it.
		if commands ~= nil then commands:push({ kind = "quit" }) end
		stopped.records[#stopped.records + 1] = { handle = handle, commands = commands, events = events }
	else
		if commands ~= nil then commands:close() end
		if events ~= nil then events:close() end
	end
end

--- Closes every source in a list, which is what a reload and a player teardown do.
---@param sources beat.PrefetchSource[]?
function Prefetch.closeAll(sources)
	if sources == nil then return end
	for at = 1, #sources do
		local source = sources[at]
		if source ~= nil then
			source:close()
			sources[at] = nil
		end
	end
end

return Prefetch
