-- A slider drawn to a canvas: the part that moves is a shape, not a style. A style built from
-- the playhead is a new style every frame, which is what the style arena warns about.
--
-- The nub is the one part of a slider the layout has to place: its box is put where the value is,
-- and it is what a drag is measured against. So it stays a child of the slider, but it paints
-- nothing -- the shape is drawn with the track -- which is what lets a repaint move it without the
-- slider being laid out again.
local wonderland = require("wonderland")

local div, sty = wonderland.div, wonderland.sty

local slider = {}

---@class beat.components.SliderProps
---@field width number
---@field value number
---@field min number? # Default 0
---@field max number? # Default 1
---@field onchange fun(value: number): any
---@field trackColour string
---@field fillColour string
---@field thumbColour string? # Default the fill colour
---@field height number? # Default theme:px(18)
---@field trackHeight number? # Default theme:px(4)
---@field thumbSize number? # Default theme:px(14)
---@field origin number? # Where the fill starts, as a fraction; default the left end
---@field liveValue fun(): number? # Where the slider is when the frame is drawn, for one that follows something moving

--- Where a value sits between the two ends of a slider, 0 at the left one and 1 at the right.
---@param value number
---@param min number
---@param max number
local function fractionOf(value, min, max)
	local span = max - min
	return math.max(0, math.min(1, span ~= 0 and (value - min) / span or 0))
end

---@param app beat.App
---@param props beat.components.SliderProps
---@return wonderland.Element
function slider.view(app, props)
	local theme = app.services.appearance.theme
	local height = props.height or theme:px(18)
	local trackHeight = props.trackHeight or theme:px(4)
	local thumbSize = props.thumbSize or theme:px(14)
	local width = props.width
	local min = props.min or 0
	local max = props.max or 1
	local fraction = fractionOf(props.value, min, max)
	local radius = trackHeight / 2
	local thumbColour = props.thumbColour or props.fillColour
	local origin = props.origin
	local liveValue = props.liveValue

	local sliderElement = div():style(sty():w(width):h(height):row():align("center")):slider({
		value = props.value,
		min = min,
		max = max,
		onchange = props.onchange
	}):children(div():style(sty():size(thumbSize, thumbSize)):thumb())

	-- What the slider draws reads the value when the frame is drawn rather than when the view was
	-- built: a repaint then shows the place the playhead is at now, and a rebuild the same place.
	sliderElement:canvas(function(canvas)
		local showed = liveValue ~= nil ? fractionOf(liveValue(), min, max) : fraction
		local y = (canvas.height - trackHeight) / 2
		-- The room the nub travels: the box less the nub itself, which is what makes the ends of
		-- the box the ends of the slider.
		local travel = math.max(0, canvas.width - thumbSize)
		local centre = showed * travel + thumbSize / 2

		canvas:rect(0, y, canvas.width, trackHeight, props.trackColour, radius)
		if origin == nil or origin == 0 then
			canvas:rect(0, y, math.max(0, centre), trackHeight, props.fillColour, radius)
		else
			local from = origin * travel + thumbSize / 2
			if centre >= from then
				canvas:rect(from, y, centre - from, trackHeight, props.fillColour, radius)
			else
				canvas:rect(centre, y, from - centre, trackHeight, props.fillColour, radius)
			end
		end

		-- The nub, where the layout put the box it paints nothing for: across the box less itself
		-- and centred on the other axis, snapped to whole pixels the way the layout snaps it. A
		-- rounded rectangle and not a circle of triangles: the corner shader antialiases it the
		-- way it did the box, while a small fan reads as a pixelated circle.
		local thumbY = math.floor((canvas.height - thumbSize) / 2 + 0.5)
		canvas:rect(math.floor(showed * travel + 0.5), thumbY, thumbSize, thumbSize, thumbColour, thumbSize / 2)
	end)

	return sliderElement
end

return slider
