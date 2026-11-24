-- A slider drawn to a canvas: the part that moves is a shape, not a style. A style built from
-- the playhead is a new style every frame, which is what the style arena warns about.
--
-- The nub is the one part of a slider the layout has to place: its box is put where the value is,
-- and it is what a drag is measured against. So it stays a child of the slider, but it paints
-- nothing -- the shape is drawn with the track -- which is what lets a repaint move it without the
-- slider being laid out again.
local wonderland = require("wonderland")
local styles = require("beat.app.components.helpers.styles")

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
---@field instance any # What tells this slider from another of the same size, kept across frames

---@class beat.components.SliderStyles
---@field track wonderland.StyleBuilder
---@field thumb wonderland.StyleBuilder
---@field draws table<any, beat.components.SliderDraw> # By instance: each slider's draw and the numbers it reads

--- The numbers one slider's draw reads. They are written when the view is built and read when the
--- frame is painted, so the slider that follows a playhead shows where it is without the view
--- making a function for it.
---@class beat.components.SliderDraw
---@field fraction number
---@field min number
---@field max number
---@field origin number?
---@field liveValue fun(): number?
---@field trackColour string
---@field fillColour string
---@field thumbColour string
---@field trackHeight number
---@field thumbSize number
---@field radius number
---@field draw fun(canvas: wonderland.Canvas)

--- Where a value sits between the two ends of a slider, 0 at the left one and 1 at the right.
---@param value number
---@param min number
---@param max number
local function fractionOf(value, min, max)
	local span = max - min
	return math.max(0, math.min(1, span ~= 0 and (value - min) / span or 0))
end

-- A slider that names no instance has this key: all its frames are the same slider, and a caller
-- that draws two of them with the same size must name them.
local NO_INSTANCE = {}

--- The draw of one slider, made where the slider's record is made rather than on every frame: a
--- function declared in the view itself is one whose upvalues the trace compiler closes each time
--- the view returns, which leaves the frame interpreted.
---@param state beat.components.SliderDraw
---@return fun(canvas: wonderland.Canvas)
local function drawFor(state)
	return function(canvas)
		local thumbSize, trackHeight, radius = state.thumbSize, state.trackHeight, state.radius
		local showed = state.liveValue ~= nil and fractionOf(state.liveValue(), state.min, state.max) or state.fraction
		local y = (canvas.height - trackHeight) / 2
		-- The room the nub travels: the box less the nub itself, which is what makes the ends of
		-- the box the ends of the slider.
		local travel = math.max(0, canvas.width - thumbSize)
		local centre = showed * travel + thumbSize / 2
		local origin = state.origin

		canvas:rect(0, y, canvas.width, trackHeight, state.trackColour, radius)
		if origin == nil or origin == 0 then
			canvas:rect(0, y, math.max(0, centre), trackHeight, state.fillColour, radius)
		else
			local from = origin * travel + thumbSize / 2
			if centre >= from then
				canvas:rect(from, y, centre - from, trackHeight, state.fillColour, radius)
			else
				canvas:rect(centre, y, from - centre, trackHeight, state.fillColour, radius)
			end
		end

		-- The nub, where the layout put the box it paints nothing for: across the box less itself
		-- and centred on the other axis, snapped to whole pixels the way the layout snaps it. A
		-- rounded rectangle and not a circle of triangles: the corner shader antialiases it the
		-- way it did the box, while a small fan reads as a pixelated circle.
		local thumbY = math.floor((canvas.height - thumbSize) / 2 + 0.5)
		canvas:rect(math.floor(showed * travel + 0.5), thumbY, thumbSize, thumbSize, state.thumbColour, thumbSize / 2)
	end
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

	-- The box and the nub it places are the same for every frame of a slider this wide, tall and
	-- with a nub this size: kept rather than made again, because the sidebar and the player bar are
	-- built again on every scroll step. Sliders that differ in any of those have a record each.
	local byHeight = styles.of(theme, "slider", width) --[[@as table<number, table<number, beat.components.SliderStyles>>]]
	local byThumb = byHeight[height]
	if byThumb == nil then
		byThumb = {}
		byHeight[height] = byThumb
	end
	local kept = byThumb[thumbSize]
	if kept == nil then
		kept = {
			track = sty():w(width):h(height):row():align("center"),
			thumb = sty():size(thumbSize, thumbSize),
			draws = {}
		}
		byThumb[thumbSize] = kept
	end

	-- What the slider draws reads the value when the frame is drawn rather than when the view was
	-- built: a repaint then shows the place the playhead is at now, and a rebuild the same place.
	-- Each slider keeps its own draw and the numbers it reads, so a screen with several of them --
	-- an equalizer's faders -- paints each one at its own place.
	local instance = props.instance
	if instance == nil then instance = NO_INSTANCE end
	local record = kept.draws[instance]
	if record == nil then
		record = {
			fraction = fraction,
			min = min,
			max = max,
			origin = origin,
			liveValue = liveValue,
			trackColour = props.trackColour,
			fillColour = props.fillColour,
			thumbColour = thumbColour,
			trackHeight = trackHeight,
			thumbSize = thumbSize,
			radius = radius
		}
		record.draw = drawFor(record)
		kept.draws[instance] = record
	end
	record.fraction, record.min, record.max = fraction, min, max
	record.origin, record.liveValue = origin, liveValue
	record.trackColour, record.fillColour, record.thumbColour = props.trackColour, props.fillColour, thumbColour

	local sliderElement = div():style(kept.track):slider({
		value = props.value,
		min = min,
		max = max,
		onchange = props.onchange
	}):children(div():style(kept.thumb):thumb())
	sliderElement:canvas(record.draw)

	return sliderElement
end

return slider
