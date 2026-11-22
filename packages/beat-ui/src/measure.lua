-- How wide a label is, before a font manager exists. The layout's automatic width means "fill the
-- room I am given", not "shrink to this text", so a button without a fixed width puts the estimate
-- on its box. It counts codepoints, giving wide scripts and emoji a full em and Latin glyphs an
-- average advance; it is the same estimate beat uses for a playlist name that has not been measured
-- by a window's font manager yet.
local utf8 = require("utf8")

local measure = {}

-- Widths already walked, by the string and then the size and the advance. A screen asks for the
-- same labels every frame -- a button's own width, a row's -- and each one is walked once. The
-- walk is what a trace cannot make sense of, so a lookup in front of it is also what keeps frames
-- out of the interpreter.
---@type table<string, table<number, table<number, number>>>
local estimates = {}
local estimated = 0
local ESTIMATE_LIMIT = 1024

---@param value string
---@param size number # The font size the text is drawn at
---@param latin number # What an average Latin glyph is worth, as a fraction of an em
---@return number
function measure.estimate(value, size, latin)
	local bySize = estimates[value]
	if bySize == nil then
		if estimated >= ESTIMATE_LIMIT then
			estimates, estimated = {}, 0
		end
		bySize = {}
		estimates[value] = bySize
		estimated += 1
	end
	local byLatin = bySize[size] or {}
	bySize[size] = byLatin
	local known = byLatin[latin]
	if known ~= nil then
		return known --[[@as number]]
	end

	local width, at = 0, 1
	local joined = false
	local previous = 0

	while at <= #value do
		local codepoint, nextAt = utf8.decode(value, at)
		at = nextAt

		if codepoint == 0x200D then
			joined = true
		elseif (codepoint >= 0x0300 and codepoint <= 0x036F) or (codepoint >= 0xFE00 and codepoint <= 0xFE0F) or (codepoint >= 0x1F3FB and codepoint <= 0x1F3FF) then
			-- A mark, a variation selector or a skin tone change is part of the picture before it.
		elseif (codepoint >= 0x1F000 and codepoint <= 0x1FAFF) or (codepoint >= 0x2600 and codepoint <= 0x27BF) then
			if joined or (codepoint >= 0x1F1E6 and codepoint <= 0x1F1FF and previous >= 0x1F1E6 and previous <= 0x1F1FF) then
				-- A joined emoji or the second half of a flag is the same picture.
			else
				width += size
			end
			joined = false
		elseif (codepoint >= 0x1100 and codepoint <= 0x115F) or (codepoint >= 0x2E80 and codepoint <= 0xA4CF) or (codepoint >= 0xAC00 and codepoint <= 0xD7A3) or (codepoint >= 0xF900 and codepoint <= 0xFAFF) or (codepoint >= 0xFE30 and codepoint <= 0xFE4F) or (codepoint >= 0xFF00 and codepoint <= 0xFF60) or (codepoint >= 0xFFE0 and codepoint <= 0xFFE6) then
			width += size
			joined = false
		else
			width += size * latin
			joined = false
		end
		previous = codepoint
	end

	width = math.max(1, math.floor(width + 0.5))
	byLatin[latin] = width
	return width
end

return measure
