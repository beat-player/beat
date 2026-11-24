-- The PCM the spectrum is made of, when the decoder is on another thread.
--
-- The tap hands over a chunk of int16 frames several times a second. Moving those through a
-- channel would copy every chunk into a Lua string and back; instead both threads map the same
-- mono float ring, allocated once with the threading library's allocator, and the audio thread
-- says how far it has written. The window the spectrum analyses ends at the frame being heard, so
-- nothing here waits for the audio thread beyond the last snapshot.
--
-- A pointer crosses as its eight raw bytes, never as a Lua number: Android tags heap pointers on
-- arm64, so an address is above 2^53 there and a double would round it somewhere else.
local ffi = require("ffi")
local native = require("threading.native")

--- The allocator the threading library exports, which is the C library's own. The type is named
--- here because what `ffi.load` hands over is a value lye cannot look inside of.
---@class beat.PcmLib
---@field threading_alloc fun(size: number): ffi.cdata*
---@field threading_free fun(pointer: ffi.cdata*)

---@type beat.PcmLib
local lib = native.lib --[[@as beat.PcmLib]]

---@class beat.PcmRing
---@field pointer ffi.cdata*? # float[CAPACITY], the same memory in both threads
---@field address string? # The eight bytes the audio thread attaches with; nil for a local ring
---@field owned boolean # Whether this side frees the memory
local PcmRing = {}
PcmRing.__index = PcmRing

-- More than the staging buffer and the device's latency put between a decoded frame and a heard
-- one, at any sample rate the player opens.
PcmRing.CAPACITY = 32768

--- A pointer as the eight raw bytes another thread reads back as a pointer. A Lua number would
--- not do: Android tags heap pointers on arm64, so an address is above 2^53 and a double rounds it
--- somewhere else.
---@param pointer ffi.cdata*
local function encode(pointer)
	return ffi.string(ffi.new("void*[1]", pointer), ffi.sizeof("void*"))
end

---@param address string
---@return ffi.cdata* pointer
local function decode(address)
	return ffi.cast("void* const*", address)[0]
end

---@param pointer ffi.cdata*
---@param address string?
---@param owned boolean
local function wrap(pointer, address, owned)
	return setmetatable({ pointer = pointer, address = address, owned = owned }, PcmRing)
end

--- A ring both threads use, in memory the audio thread may write and this one reads.
---@return beat.PcmRing
function PcmRing.shared()
	local bytes = PcmRing.CAPACITY * ffi.sizeof("float")
	local pointer = ffi.cast("float*", lib.threading_alloc(bytes))
	if pointer == nil then error("beat: out of memory for the spectrum") end
	ffi.fill(pointer, bytes)
	return wrap(pointer, encode(pointer), true)
end

--- The ring another thread made, from the address it handed over.
---@param address string
---@return beat.PcmRing
function PcmRing.fromAddress(address)
	local pointer = ffi.cast("float*", decode(address))
	assert(pointer ~= nil, "beat: the spectrum's ring address is empty")
	return wrap(pointer, address, false)
end

function PcmRing:free()
	local pointer = self.pointer
	if not self.owned or pointer == nil then return end
	lib.threading_free(pointer)
	self.pointer = nil
	self.address = nil
	self.owned = false
end

return PcmRing
