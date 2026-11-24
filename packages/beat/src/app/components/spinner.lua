-- The small mark that says a track is being opened, not playing yet.
--
-- It is a canvas because it moves: an arc that turns while a slow file is being read. It turns
-- with reduced motion on as well: it is the one thing on screen saying the app is working, and a
-- still arc reads as stuck. The draw is made once per size and colour and kept on the theme, like
-- every other mark the rows and buttons draw.
--
-- The arc is a run of small round dots close enough to overlap. A dot is a rounded box, which the
-- shader cuts with an antialiased edge; a canvas line or circle is a polygon with hard edges, and
-- an arc of those looked like a chain of steps at a button's size.
local wonderland = require("wonderland")

local div, sty = wonderland.div, wonderland.sty

local spinner = {}

-- How far the arc reaches. The dots that make it are spaced at a third of the thinnest one, so
-- neighbours always overlap into one stroke whatever size a button or row asks for.
local SPAN = math.pi * 1.4
local SECONDS_PER_TURN = 0.9
-- The tail thins to this share of the head's thickness, so the arc reads as moving one way.
local TAIL = 0.35

---@class beat.components.SpinnerMark
---@field style wonderland.StyleBuilder
---@field draw fun(canvas: wonderland.Canvas)

---@param colour string
---@return fun(canvas: wonderland.Canvas)
local function makeDraw(colour)
	return function(canvas)
		local size = math.min(canvas.width, canvas.height)
		local radius = size * 0.34
		local thickness = math.max(2, size * 0.12)
		local cx, cy = canvas.width / 2, canvas.height / 2
		local head = wonderland.time.now() * (math.pi * 2 / SECONDS_PER_TURN)
		local dots = math.ceil(SPAN * radius / (thickness * TAIL / 3)) + 1
		for at = 0, dots - 1 do
			-- From the tail to the head, so the thicker head is drawn over the tail it overlaps.
			local share = at / (dots - 1)
			local angle = head - SPAN * (1 - share)
			local dot = thickness * (TAIL + (1 - TAIL) * share)
			local half = dot / 2
			canvas:rect(cx + math.cos(angle) * radius - half, cy + math.sin(angle) * radius - half, dot, dot, colour, half)
		end
	end
end

---@param app beat.App
---@param size number # The square the mark is drawn in
---@param colour string # The arc's colour, usually the accent or the ink on an accent button
---@return wonderland.Element
function spinner.view(app, size, colour)
	---@type table<string, any>
	local cache = app.services.appearance.theme:cache()
	local bySize = cache.spinnerMarks --[[@as table<number, table<string, beat.components.SpinnerMark>>?]]
	if bySize == nil then
		bySize = {}
		cache.spinnerMarks = bySize
	end
	local byColour = bySize[size]
	if byColour == nil then
		byColour = {}
		bySize[size] = byColour
	end
	local mark = byColour[colour]
	if mark == nil then
		mark = { style = sty():size(size, size), draw = makeDraw(colour) }
		byColour[colour] = mark
	end

	return div():style(mark.style):canvas(mark.draw)
end

return spinner
