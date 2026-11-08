-- A slider drawn to a canvas: the part that moves is a shape, not a style. A style built from
-- the playhead is a new style every frame, which is what the style arena warns about.
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
	local span = max - min
	local value = span ~= 0 and (props.value - min) / span or 0
	local fraction = math.max(0, math.min(1, value))
	local radius = trackHeight / 2
	local thumbColour = props.thumbColour or props.fillColour

	local sliderElement = div():style(sty():w(width):h(height):row():align("center"))
	:slider({
		value = props.value,
		min = min,
		max = max,
		onchange = props.onchange,
	})
	-- The nub is a styled box, not a canvas polygon: the renderer antialiases rounded
	-- corners, while a small fan of triangles reads as a pixelated circle.
	:children(div():style(sty():size(thumbSize, thumbSize):radius(thumbSize / 2)
	:bg(thumbColour)):thumb())

	sliderElement:canvas(function(canvas)
		local y = (canvas.height - trackHeight) / 2
		local track = math.max(0, canvas.width - thumbSize)
		local centre = fraction * track + thumbSize / 2

		canvas:rect(0, y, canvas.width, trackHeight, props.trackColour, radius)
		if props.origin == nil or props.origin == 0 then
			canvas:rect(0, y, math.max(0, centre), trackHeight, props.fillColour, radius)
		else
			local origin = props.origin * track + thumbSize / 2
			if centre >= origin then
				canvas:rect(origin, y, centre - origin, trackHeight, props.fillColour, radius)
			else
				canvas:rect(centre, y, origin - centre, trackHeight, props.fillColour, radius)
			end
		end
	end)

	return sliderElement
end

return slider
