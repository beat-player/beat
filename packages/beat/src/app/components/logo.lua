-- The beat brand mark: its own five bars, not an Ionicons glyph. It is drawn rather than taken
-- from the icon face so the shell's logo stays the artwork the app was designed around.
local wonderland = require("wonderland")

local div, sty = wonderland.div, wonderland.sty

local logo = {}

---@class beat.components.LogoProps
---@field size number # The square the mark is drawn in
---@field colour string # The bars' fill

-- The five bars of the original beat mark, in the 512-unit space of the icon that was used before
-- the rest of the set moved to Ionicons: left, top and height each. Kept as numbers so the draw
-- reads them rather than building a closure per bar.
local BARS = { 64, 213, 86, 149, 128, 256, 235, 43, 426, 320, 128, 256, 405, 213, 86 }
local BAR_WIDTH = 43

---@param canvas wonderland.Canvas
---@param colour string
local function drawMark(canvas, colour)
	local unit = math.min(canvas.width, canvas.height) / 512
	local width = BAR_WIDTH * unit
	for at = 1, #BARS, 3 do
		canvas:rect(BARS[at] * unit, BARS[at + 1] * unit, width, BARS[at + 2] * unit, colour, width / 2)
	end
end

--- The canvas draw for one colour. It is made here rather than in the view so the view itself
--- defines no function: a frame that leaves a closure behind at every return is a trace that
--- cannot be compiled.
---@param colour string
---@return fun(canvas: wonderland.Canvas)
local function markDraw(colour)
	return function(canvas) drawMark(canvas, colour) end
end

-- The mark's box only depends on its size, and its draw on its colour, so the two are kept per app
-- rather than per theme: a theme change keeps the boxes and asks for a draw in the new accent.
---@type table<beat.App, table<number, wonderland.StyleBuilder>>
local boxesByApp = setmetatable({}, { __mode = "k" })
---@type table<beat.App, table<string, fun(canvas: wonderland.Canvas)>>
local drawsByApp = setmetatable({}, { __mode = "k" })

---@param app beat.App
---@param props beat.components.LogoProps
---@return wonderland.Element
function logo.view(app, props)
	local size, colour = props.size, props.colour

	local boxes = boxesByApp[app]
	if boxes == nil then
		boxes = {}
		boxesByApp[app] = boxes
	end
	local box = boxes[size] or sty():size(size, size)
	boxes[size] = box

	local draws = drawsByApp[app]
	if draws == nil then
		draws = {}
		drawsByApp[app] = draws
	end
	local draw = draws[colour] or markDraw(colour)
	draws[colour] = draw

	return div():style(box):canvas(draw)
end

return logo
