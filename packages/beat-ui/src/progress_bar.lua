-- A thin bar that shows how far work has got. A value gives a determinate fill; `indeterminate`
-- gives the moving band a job of unknown length uses. The value is clamped to 0..1, so a caller
-- cannot draw a fill past either end of the track.
local wonderland = require("wonderland")
local cache = require("beat-ui.cache")

local div, sty = wonderland.div, wonderland.sty
local time = wonderland.time

local progressBar = {}

--- Clamps a progress value to 0..1. A value that is not a number -- or is NaN -- means "no value",
--- which draws an empty track unless `indeterminate` asks for the moving band.
---@param value any
---@return number?
function progressBar.fraction(value)
	if type(value) ~= "number" or value ~= value then return nil end
	return math.max(0, math.min(1, value))
end

---@class beat.ui.ProgressBarProps
---@field value number? # 0..1; omitted for an empty or indeterminate bar
---@field indeterminate boolean? # Draw a moving band while there is no value
---@field width number? # Default fills the room its parent gives it
---@field height number? # Default px(4)
---@field tone string? # A theme colour token; default "accent"

--- The track is a height and a width; what is drawn in it changes with the value, which is what
--- the canvas is for, but the box around it does not.
---@param ctx beat.ui.Context
---@param height number
---@param width number|string # The width, or "rel"
---@return wonderland.StyleBuilder
local function trackStyle(ctx, height, width)
	local style = sty():h(height):radius(ctx:radius("full"))
	if type(width) == "number" then
		style:w(width)
	else
		style:wrel(1.0)
	end
	return style
end

---@param ctx beat.ui.Context
---@param props beat.ui.ProgressBarProps
---@return wonderland.Element
function progressBar.view(ctx, props)
	local height = props.height or ctx:px(4)
	local fraction = progressBar.fraction(props.value)
	local moving = fraction == nil and props.indeterminate == true
	local tone = ctx:color(props.tone or "accent")
	local track = ctx:color("text", 0.12)

	local style = cache.of(ctx, trackStyle, "progressBar", height, props.width or "rel") --[[@as wonderland.StyleBuilder]]

	---@param canvas wonderland.Canvas
	local function draw(canvas)
		canvas:rect(0, 0, canvas.width, canvas.height, track, canvas.height / 2)
		if moving then
			local band = canvas.width * 0.3
			local span = canvas.width + band
			local start = (time.now() * 0.6) % 1 * span - band
			local left = math.max(0, start)
			local right = math.min(canvas.width, start + band)
			if right > left then
				canvas:rect(left, 0, right - left, canvas.height, tone, canvas.height / 2)
			end
		elseif fraction ~= nil and fraction > 0 then
			canvas:rect(0, 0, math.floor(canvas.width * fraction), canvas.height, tone, canvas.height / 2)
		end
	end

	return div():style(style):clip():canvas(draw)
end

return progressBar
