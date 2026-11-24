-- The pixels a cover worker decodes, handed to the window without a Lua string.
--
-- A cover is a million bytes or more. A string of that crosses from the worker's Lua state into
-- the window's by being encoded, allocated and decoded again, so every cover scrolled into view
-- leaves megabytes of garbage on the window's heap for the collector to walk. What crosses here
-- is only the address: the worker allocates the buffer with the allocator the threading library
-- uses, the window casts the address, uploads from it, and frees it. No pixel is ever part of a
-- Lua value, and the window's heap does not see the picture at all.
local ffi = require("ffi")
local native = require("threading.native")

--- The allocator the threading library exports, which is the C library's own: a buffer one state
--- makes is one another can give back. The type is named here because what `ffi.load` hands over
--- is a value lye cannot look inside of.
---@class beat.CoverPixelLib
---@field threading_alloc fun(size: number): ffi.cdata*
---@field threading_free fun(pointer: ffi.cdata*)

---@type beat.CoverPixelLib
local lib = native.lib --[[@as beat.CoverPixelLib]]

local coverPixels = {}

--- A pointer as eight bytes, which is what a worker can hand back through `threading` without
--- losing any of it. A Lua number would not do: Android tags the top byte of every heap pointer on
--- arm64, so an address is above 2^53 there and a double rounds it to somewhere else -- the window
--- then reads and frees memory that is not the picture. The string is the pointer's own bytes, not
--- its digits, and it is read back as a pointer rather than as an integer: a 64-bit integer that
--- passes through a double on its way to being a pointer is rounded the same way, and on arm64 an
--- out-of-range conversion saturates to 0x7fffffffffffffff.
---@param pointer ffi.cdata*
---@return string
function coverPixels.address(pointer)
	return ffi.string(ffi.new("void*[1]", pointer), ffi.sizeof("void*"))
end

---@param address string
---@return ffi.cdata* pointer
function coverPixels.pointer(address)
	return ffi.cast("uint8_t* const*", address)[0]
end

--- A buffer of `bytes` that `free` gives back. Nil when the allocator has none, which a caller
--- treats the same as a picture that did not decode.
---@param bytes number
---@return string? address
function coverPixels.alloc(bytes)
	local pointer = ffi.cast("void*", lib.threading_alloc(bytes))
	if pointer == nil then return nil end
	return coverPixels.address(pointer)
end

--- Gives back a buffer `alloc` made, or one a worker handed over. Nothing reads the address
--- afterwards: the upload has already copied the pixels into the texture's staging memory.
---@param address string?
function coverPixels.free(address)
	if address == nil then return end
	lib.threading_free(coverPixels.pointer(address))
end

--- The cached cover of one album, fitted for this screen, as pixels the window frees once it has
--- uploaded them and the colour its page tints with.
---
--- The fitted image is copied once, straight into the buffer that crosses, and closed at once:
--- the decode's own buffer is let go of while the worker still has it rather than left for the
--- collector of a state that never runs again. Failed work is last on purpose -- an answer that
--- cannot be copied back must not leave a buffer nobody has the address of.
---@param coverCache string
---@param size number
---@return number? width
---@return number? height
---@return string? address
---@return { r: number, g: number, b: number }? colour
function coverPixels.decode(coverCache, size)
	local artwork = require("beat.music.artwork")
	local fitted, colour = artwork.forAlbum({ coverCache = coverCache } --[[@as beat.Album]], size)
	if fitted == nil then return nil end

	local width, height = fitted.width, fitted.height
	local bytes = width * height * 4
	local address = coverPixels.alloc(bytes)
	if address == nil then
		fitted:close()
		return nil
	end

	ffi.copy(coverPixels.pointer(address), fitted.pixels, bytes)
	fitted:close()

	return width, height, address, colour
end

return coverPixels
