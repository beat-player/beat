-- MD5 (RFC 1321), for Last.fm's api_sig. Pure Lua with LuaJIT bit operations: one short string
-- per scrobble is not a hot path, and this keeps signing available on every platform without a
-- native dependency.
local bit = require("bit")

--- floor(abs(sin(i + 1)) * 2^32), the RFC 1321 constant table.
local K = {
	0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
	0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
	0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
	0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
	0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
	0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
	0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
	0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
}

-- Per-round left-rotation amounts.
local S = {
	7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
	5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
	4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
	6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

---@param a number
---@param b number
---@return number # 32-bit sum
local function add(a, b)
	return bit.tobit(a + b)
end

--- Message with the 0x80 terminator, zero padding and the 64-bit little-endian bit length
--- appended, so the result is a whole number of 64-byte blocks.
---@param message string
---@return string
local function pad(message)
	local bitLength = #message * 8
	local zeros = (56 - (#message + 1) % 64) % 64
	local low = bitLength % 0x100000000
	local high = math.floor(bitLength / 0x100000000)

	return message .. "\128" .. string.rep("\0", zeros)
	.. string.char(low % 256, math.floor(low / 256) % 256, math.floor(low / 65536) % 256,
	math.floor(low / 16777216) % 256, high % 256, math.floor(high / 256) % 256,
	math.floor(high / 65536) % 256, math.floor(high / 16777216) % 256)
end

---@param message string
---@return number, number, number, number # a, b, c, d (host order)
local function blockDigest(message)
	local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
	local data = pad(message)

	for blockStart = 1, #data, 64 do
		-- 16 little-endian 32-bit words of this block.
		local x = {}
		local byte = blockStart
		for i = 1, 16 do
			local b1, b2, b3, b4 = string.byte(data, byte, byte + 3)
			x[i] = bit.bor(bit.bor(b1, bit.lshift(b2, 8)),
			bit.bor(bit.lshift(b3, 16), bit.lshift(b4, 24)))
			byte = byte + 4
		end

		local a, b, c, d = a0, b0, c0, d0
		for i = 1, 64 do
			local f, g
			if i <= 16 then
				f, g = bit.bor(bit.band(b, c), bit.band(bit.bnot(b), d)), i
			elseif i <= 32 then
				f, g = bit.bor(bit.band(d, b), bit.band(bit.bnot(d), c)), (5 * i - 4) % 16 + 1
			elseif i <= 48 then
				f, g = bit.bxor(bit.bxor(b, c), d), (3 * i + 2) % 16 + 1
			else
				f, g = bit.bxor(c, bit.bor(b, bit.bnot(d))), (7 * i - 7) % 16 + 1
			end
			f = add(f, add(add(a, K[i]), x[g]))
			a, b, c, d = d, add(b, bit.rol(f, S[i])), b, c
		end

		a0, b0, c0, d0 = add(a0, a), add(b0, b), add(c0, c), add(d0, d)
	end

	return a0, b0, c0, d0
end

---@param value number
---@return number
local function unsigned(value)
	return value % 0x100000000
end

---@param value number
---@return string
local function littleEndianHex(value)
	local word = unsigned(value)
	local b1 = word % 256
	local b2 = math.floor(word / 256) % 256
	local b3 = math.floor(word / 65536) % 256
	local b4 = math.floor(word / 16777216) % 256

	return string.format("%02x%02x%02x%02x", b1, b2, b3, b4)
end

--- Hex digest of `message`, lowercase and 32 characters, as Last.fm expects it.
---@param message string
---@return string
local function sumhexa(message)
	local a, b, c, d = blockDigest(message)

	return littleEndianHex(a) .. littleEndianHex(b) .. littleEndianHex(c) .. littleEndianHex(d)
end

return { sumhexa = sumhexa}
