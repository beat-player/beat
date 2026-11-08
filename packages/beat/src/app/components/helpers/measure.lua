-- How much room a string takes: estimated from its codepoints before a font exists, measured by
-- the text plugin once one does, and broken into lines for a width.
local wonderland = require("wonderland")
local utf8 = require("utf8")
local wonderlandElement = require("wonderland.element")

local measure = {}

--- How wide a string is, in the units this app sizes a text box from. A Lua length is bytes, not
--- characters: an emoji is four of them and a flag or a family is several codepoints that draw as
--- one picture. Counting codepoints, then giving wide scripts and emoji a full em while Latin
--- glyphs get an average advance, is enough to keep a label's box against its ink without asking
--- the font manager during a page build.
---@param value string
---@param size number # The font size it will be drawn at
---@param latin number # What an average Latin glyph is worth, as a fraction of an em
---@return number
function measure.estimate(value, size, latin)
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

	return math.max(1, math.floor(width + 0.5))
end

--- The run Wonderland measures for a string, through the same text plugin that will draw it: its
--- width and, for a string of several lines, its height. Nil before a window's font manager exists.
---@param app beat.App
---@param value string
---@param style wonderland.StyleBuilder
---@return wonderland.font.Run?
function measure.run(app, value, style)
	local layout = app.layoutPlugin
	if layout == nil or layout.textPlugin == nil then return nil end
	local line = wonderland.text(value):style(style)
	local ok = pcall(layout.textPlugin.measure, layout.textPlugin, line)
	if not ok or line.run == 0 then return nil end
	return wonderlandElement.runOf(line)
end

--- The width Wonderland measures for a line. A style's automatic width means "fill the room I am
--- given", not "shrink to this text", so the app asks for the measured run and puts that width on
--- the box. The codepoint estimate above is only a fallback for a page built before a window's
--- font manager exists.
---@param app beat.App
---@param value string
---@param style wonderland.StyleBuilder
---@return number?
function measure.width(app, value, style)
	local run = measure.run(app, value, style)
	return run?.width
end

-- Wrapped strings by width, size and text. A toast is drawn every frame while it fades, and its
-- lines are only worth working out once.
---@type table<string, string[]>
local wrapCache = {}
local wrapCached = 0

--- The lines a string breaks into to fit `width`: after a space or a path separator, and inside a
--- word only where the word alone is wider than the line. Wonderland draws the lines it is given
--- and breaks none itself. Past `most` lines the last one ends in an ellipsis.
---@param app beat.App
---@param value string
---@param style wonderland.StyleBuilder
---@param size number # The font size, for the estimate used before a font is loaded
---@param width number
---@param most number
---@return string[]
function measure.wrap(app, value, style, size, width, most)
	local key = width .. ":" .. size .. ":" .. most .. ":" .. value
	local cached = wrapCache[key]
	if cached ~= nil then return cached end

	local function fits(line)
		return (measure.width(app, line, style) or measure.estimate(line, size, 0.55)) <= width
	end
	local function trimmed(line) return (line:gsub(" +$", "")) end

	---@type string[]
	local lines = {}
	local line = ""
	for piece in value:gmatch("[^ \\/]*[ \\/]*") do
		if piece ~= "" then
			if line == "" or fits(trimmed(line .. piece)) then
				line ..= piece
			else
				lines[#lines + 1] = trimmed(line)
				line = piece
			end
			-- A word wider than a whole line is cut where it stops fitting.
			while not fits(trimmed(line)) do
				local at, cut = 1, nil
				while at <= #line do
					local _, nextAt = utf8.decode(line, at)
					if cut ~= nil and not fits(line:sub(1, nextAt - 1)) then break end
					cut, at = nextAt - 1, nextAt
				end
				lines[#lines + 1] = line:sub(1, cut)
				line = line:sub(cut + 1)
			end
		end
	end
	if trimmed(line) ~= "" then lines[#lines + 1] = trimmed(line) end

	if #lines > most then
		for at = #lines, most + 1, -1 do lines[at] = nil end
		local last = lines[most]
		while #last > 0 and not fits(last .. "…") do
			local at, before = 1, 0
			while at <= #last do
				before = at
				local _, nextAt = utf8.decode(last, at)
				at = nextAt
			end
			last = last:sub(1, before - 1)
		end
		lines[most] = trimmed(last) .. "…"
	end

	if wrapCached >= 64 then wrapCache, wrapCached = {}, 0 end
	wrapCache[key], wrapCached = lines, wrapCached + 1
	return lines
end

return measure
