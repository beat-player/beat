-- Text as search compares it: lowercase, accents taken off Latin letters, punctuation turned into
-- single spaces and apostrophes dropped, so "Beyoncé", "BEYONCE" and "beyonce" are one word, and
-- "Don't" and "dont" are too. Letters of other scripts are kept as they are written.
--
-- A fold walks the bytes once into one reused string.buffer and makes one string at the end: no
-- per-character strings, no patterns. The tables below are filled once when the file loads.
local buffer = require("string.buffer")

local fold = {}

-- What an ASCII byte becomes: the one-character string to write, SPACE for a separator, or DROP
-- for nothing. The strings are made here once, so a fold writes them rather than making them.
local SPACE, DROP = -1, -2
---@type table<number, string|number>
local asciiFold = {}
for code = 0, 127 do asciiFold[code] = SPACE end
for code = 48, 57 do asciiFold[code] = string.char(code) end -- 0-9
for code = 97, 122 do asciiFold[code] = string.char(code) end -- a-z
for code = 65, 90 do asciiFold[code] = string.char(code + 32) end -- A-Z
asciiFold[39] = DROP -- ' is inside a word, not between two

-- Accented Latin letters and the letter each one is typed as, one character per code point from
-- the start of a range; "_" marks a code point with no plain letter, and the few that fold to two
-- letters are set after.
local RANGES = {
	-- U+00C0: Latin-1 Supplement capitals and small letters.
	{ 0x00C0, "aaaaaa_ceeeeiiiidnooooo ouuuuy_saaaaaa_ceeeeiiiidnooooo ouuuuy_y" },
	-- U+0100: Latin Extended-A.
	{ 0x0100, "aaaaaaccccccccddddeeeeeeeeeegggggggghhhhiiiiiiiiii__jjkkkllllllllllnnnnnnnnnoooooo__rrrrrrsssssssstttttt"
		.. "uuuuuuuuuuuuwwyyyzzzzzzs" },
	-- U+01CD: the caron vowels of Latin Extended-B.
	{ 0x01CD, "aaiioouuuuuuuuuu" },
}
local TWO_LETTERS = {
	[0x00C6] = "ae", [0x00E6] = "ae", [0x00DE] = "th", [0x00FE] = "th", [0x00DF] = "ss",
	[0x0132] = "ij", [0x0133] = "ij", [0x0152] = "oe", [0x0153] = "oe"
}
-- Quotes, dashes and spaces from outside ASCII, which a title copied from the web carries.
local SEPARATORS = { 0x00A0, 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x201C, 0x201D, 0x2026 }
local DROPPED = { 0x2018, 0x2019, 0x02BC }

---@type table<number, string|number>
local codeFold = {}
for _, range in ipairs(RANGES) do
	local first, letters = range[1], range[2]
	for at = 1, #letters do
		local letter = letters:sub(at, at)
		if letter == " " then
			codeFold[first + at - 1] = SPACE
		elseif letter ~= "_" then
			codeFold[first + at - 1] = letter
		end
	end
end
for code, letters in pairs(TWO_LETTERS) do codeFold[code] = letters end
for _, code in ipairs(SEPARATORS) do codeFold[code] = SPACE end
for _, code in ipairs(DROPPED) do codeFold[code] = DROP end

local out = buffer.new(256)

--- `value` folded for search, with single spaces between words and none at either end.
---@param value string?
---@return string
function fold.text(value)
	if value == nil or value == "" then return "" end
	out:reset()
	local byte = string.byte
	local length = #value
	local wrote, owed = false, false
	local at = 1
	while at <= length do
		local b = byte(value, at)
		local result, width
		if b < 0x80 then
			result, width = asciiFold[b], 1
		else
			-- A UTF-8 lead byte says how many bytes the character takes; a stray continuation byte
			-- is kept as one, so text that is not valid UTF-8 still folds to something searchable.
			width = b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC0 and 2 or 1
			local code
			if width == 2 then
				code = (b - 0xC0) * 64 + (byte(value, at + 1) or 0x80) - 0x80
			elseif width == 3 then
				code = ((b - 0xE0) * 64 + (byte(value, at + 1) or 0x80) - 0x80) * 64 + (byte(value, at + 2) or 0x80) - 0x80
			end
			result = code ~= nil and codeFold[code] or nil
			if result == nil then result = value:sub(at, at + width - 1) end
		end

		if result == SPACE then
			owed = wrote
		elseif result ~= DROP then
			if owed then
				out:put(" ")
				owed = false
			end
			out:put(result)
			wrote = true
		end
		at = at + width
	end
	return out:tostring()
end

return fold
