-- The small mark that says a track is being opened, not playing yet.
--
-- It is a canvas because it moves: a rotating arc while a slow file is being read, and three still
-- dots when the listener asked motion to be reduced. The draw is made once per size, colour and
-- motion setting and kept on the theme, like every other mark the rows and buttons draw.
local wonderland = require("wonderland")

local div, sty = wonderland.div, wonderland.sty

local spinner = {}

-- How far the arc reaches, and how many straight pieces make it: short enough to read as a
-- spinner, few enough that the canvas does not draw a hundred lines a frame.
local SPAN = math.pi * 0.62
local SEGMENTS = 7
local SECONDS_PER_TURN = 1.25

---@class beat.components.SpinnerMark
---@field style wonderland.StyleBuilder
---@field draw fun(canvas: wonderland.Canvas)

---@param colour string
---@param reduceMotion boolean
---@return fun(canvas: wonderland.Canvas)
local function makeDraw(colour, reduceMotion)
	if reduceMotion then
		-- Three still dots, the same mark every frame: reduced motion must not turn the wait into
		-- something that moves.
		return function(canvas)
			local radius = math.min(canvas.width, canvas.height) * 0.075
			local orbit = math.min(canvas.width, canvas.height) * 0.27
			local cx, cy = canvas.width / 2, canvas.height / 2
			for at = 0, 2 do
				local angle = at * math.pi * 2 / 3
				canvas:circle(cx + math.cos(angle) * orbit, cy + math.sin(angle) * orbit, radius, colour, 12)
			end
		end
	end

	return function(canvas)
		local size = math.min(canvas.width, canvas.height)
		local radius = size * 0.32
		local thickness = math.max(1.5, size * 0.105)
		local cx, cy = canvas.width / 2, canvas.height / 2
		local start = wonderland.time.now() * (math.pi * 2 / SECONDS_PER_TURN)
		local previousX, previousY
		for at = 0, SEGMENTS do
			local angle = start + SPAN * at / SEGMENTS
			local x = cx + math.cos(angle) * radius
			local y = cy + math.sin(angle) * radius
			if at > 0 then canvas:line(previousX, previousY, x, y, thickness, colour) end
			previousX, previousY = x, y
		end
	end
end

---@param app beat.App
---@param size number # The square the mark is drawn in
---@param colour string # The arc's colour, usually the accent or the ink on an accent button
---@return wonderland.Element
function spinner.view(app, size, colour)
	local theme = app.services.appearance.theme
	local reduceMotion = app.services.settings.values.reduceMotion == true

	---@type table<string, any>
	local cache = theme:cache()
	local bySize = cache.spinnerMarks --[[@as table<number, table<string, table<boolean, beat.components.SpinnerMark>>>?]]
	if bySize == nil then
		bySize = {}
		cache.spinnerMarks = bySize
	end
	local byColour = bySize[size]
	if byColour == nil then
		byColour = {}
		bySize[size] = byColour
	end
	local byMotion = byColour[colour]
	if byMotion == nil then
		byMotion = {}
		byColour[colour] = byMotion
	end
	local mark = byMotion[reduceMotion]
	if mark == nil then
		mark = { style = sty():size(size, size), draw = makeDraw(colour, reduceMotion) }
		byMotion[reduceMotion] = mark
	end

	return div():style(mark.style):canvas(mark.draw)
end

return spinner
