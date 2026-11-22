-- The spectrum as a quiet background for the playing bar. It is deliberately faint and wide:
-- content sits over it, so this is texture rather than a second meter.
local wonderland = require("wonderland")
local metrics = require("beat.app.components.helpers.metrics")

local div, sty = wonderland.div, wonderland.sty

local spectrumBackground = {}

-- The strip: the most bars it draws, and the least it draws however narrow the window is. A phone
-- is a third of a desktop's width at three times the density, so a fixed count makes bars that read
-- as hairlines there; the count follows the width instead. A bar is at least eight theme pixels
-- wide, and the gap is the room between two of them.
local MAX_COUNT = 72
local MIN_COUNT = 24

-- A phone's strip is wider and fewer: a screen that small is read at a distance, where eight-pixel
-- bars dissolve into the background, so they get about twice the width. The lower floor keeps a
-- narrow screen from clamping them back to hairlines.
local MOBILE_BAR_WIDTH = 14
local MOBILE_GAP = 3
local MOBILE_MIN_COUNT = 18

-- The opacity of a bar at rest and the extra a full level adds. The phone uses the same curve
-- lifted by about three quarters: close to twice the wash without turning texture into a meter.
local ALPHA_FLOOR = 0.035
local ALPHA_RANGE = 0.09
local MOBILE_ALPHA_FLOOR = 0.06
local MOBILE_ALPHA_RANGE = 0.16

--- The bars of a strip `width` pixels wide: how many there are, the room between them, and the
--- width of one.
---@param theme beat.Theme
---@param width number
---@param mobile boolean
---@return number count
---@return number gap
---@return number barWidth
local function barLayout(theme, width, mobile)
	local gap = mobile and math.max(MOBILE_GAP, theme:px(MOBILE_GAP)) or math.max(2, theme:px(2))
	local least = mobile and math.max(24, theme:px(MOBILE_BAR_WIDTH)) or math.max(16, theme:px(8))
	local count = math.floor((width + gap) / (least + gap))
	local fewest = mobile and MOBILE_MIN_COUNT or MIN_COUNT

	if count < fewest then count = fewest end
	if count > MAX_COUNT then count = MAX_COUNT end

	return count, gap, math.max(1, (width - gap * (count - 1)) / count)
end

--- The accent's channels, which the shapes of the meter are drawn in. A canvas takes a colour as
--- the string a theme hands out or as the four fractions of one, and the fractions cost nothing
--- per bar where the string is parsed and the alpha formatted for every bar of every frame.
---@param theme beat.Theme
local function accentChannels(theme)
	---@type table<string, any>
	local cache = theme:cache()
	local accent = cache.spectrumAccent --[[@as { r: number, g: number, b: number }?]]
	if accent == nil then
		local hex = theme:color("accent"):match("#(%x%x%x%x%x%x)") or "c9f45b"
		accent = {
			r = (tonumber(hex:sub(1, 2), 16) or 0) / 255,
			g = (tonumber(hex:sub(3, 4), 16) or 0) / 255,
			b = (tonumber(hex:sub(5, 6), 16) or 0) / 255
		}
		cache.spectrumAccent = accent
	end
	return accent
end

--- The strip, in the room the element was given. The levels are read here, when the shapes are
--- drawn, and not when the view was built: the service mutates the table it hands out, so a
--- repaint of the screen already built draws the meter as it is now. A strip that is silent draws
--- nothing, which is what the bar looked like before anything played.
---@param app beat.App
---@param canvas wonderland.Canvas
---@param theme beat.Theme
---@param levels number[]
---@param intensity number
---@param reach number
local function drawMeter(app, canvas, theme, levels, intensity, reach)
	local active = false
	for at = 1, #levels do
		if levels[at] > 0.01 then
			active = true
			break
		end
	end
	if not active then return end

	-- The phone breakpoint is the window's, read from the strip's own width so the same view is a
	-- phone or a desktop depending on the window it lands in.
	local mobile = metrics.mobile(app, canvas.width)
	local baseAlpha = mobile and MOBILE_ALPHA_FLOOR or ALPHA_FLOOR
	local levelAlpha = mobile and MOBILE_ALPHA_RANGE or ALPHA_RANGE
	local accent = accentChannels(theme)
	-- The two shapes of a bar, kept as tables across the loop: a canvas reads the colour when the
	-- shape is added to the frame, so only the alpha has to be set for each bar.
	local wash = { r = accent.r, g = accent.g, b = accent.b, a = 0 }
	local core = { r = accent.r, g = accent.g, b = accent.b, a = 0 }
	local count, gap, barWidth = barLayout(theme, canvas.width, mobile)
	local spread = math.max(1, count - 1)

	for at = 1, count do
		local position = (at - 1) / spread * (#levels - 1) + 1
		local lower = math.floor(position)
		local upper = math.min(#levels, lower + 1)
		local mix = position - lower
		local level = (levels[lower] or 0) * (1 - mix) + (levels[upper] or 0) * mix
		local barHeight = math.max(2, level * canvas.height * reach)
		local x = (at - 1) * (barWidth + gap)
		local alpha = (baseAlpha + level * levelAlpha) * intensity

		-- A wider, nearly transparent pass and a narrower core: at this opacity it reads as a
		-- blurred wash behind the bar rather than a row of hard rectangles.
		wash.a = alpha * 0.35
		canvas:rect(x - 2, canvas.height - barHeight - 1, barWidth + 4, barHeight + 1, wash, 3)
		core.a = alpha
		canvas:rect(x, canvas.height - barHeight, barWidth, barHeight, core, math.max(1, barWidth / 3))
	end
end

--- The strip's draw, kept for the theme and what it is asked for rather than made for every
--- frame: the bar and the now-playing screen ask for it with their own intensity, and a closure
--- made in the view is one the trace compiler gives up on.
--- One strip a frame draws, as its draw and the levels it was made for.
---@class beat.components.SpectrumMeter
---@field levels number[]
---@field draw fun(canvas: wonderland.Canvas)

---@param app beat.App
---@param theme beat.Theme
---@param levels number[]
---@param intensity number
---@param reach number
---@return fun(canvas: wonderland.Canvas)
local function meterOf(app, theme, levels, intensity, reach)
	---@type table<string, any>
	local cache = theme:cache()
	local meters = cache.spectrumMeters --[[@as table<number, table<number, beat.components.SpectrumMeter>>?]]
	if meters == nil then
		meters = {}
		cache.spectrumMeters = meters
	end

	local byIntensity = meters[intensity]
	if byIntensity == nil then
		byIntensity = {}
		meters[intensity] = byIntensity
	end
	local meter = byIntensity[reach]
	if meter == nil or meter.levels ~= levels then
		---@param canvas wonderland.Canvas
		local function draw(canvas)
			drawMeter(app, canvas, theme, levels, intensity, reach)
		end

		meter = { levels = levels, draw = draw }
		byIntensity[reach] = meter
	end
	return meter.draw
end

---@class beat.components.SpectrumBackgroundProps
---@field intensity number? # Scales the wash's opacity; default 1
---@field reach number? # How much of the bar's height the tallest bar takes; default 0.82

--- The element fills the box it is given and takes no room in it, so a caller can place it as a
--- layer behind its siblings.
---@param app beat.App
---@param props beat.components.SpectrumBackgroundProps
---@return wonderland.Element
function spectrumBackground.view(app, props)
	local intensity = props.intensity or 1
	local reach = props.reach or 0.82
	local theme = app.services.appearance.theme
	local spectrum = app.services.playback.spectrum
	local levels = spectrum ~= nil ? (spectrum:values()) : {}

	---@type table<string, any>
	local cache = theme:cache()
	local style = cache.spectrumBackground --[[@as wonderland.StyleBuilder?]]
	if style == nil then
		style = sty():fill():offset(0, 0)
		cache.spectrumBackground = style
	end

	return div():style(style):canvas(meterOf(app, theme, levels, intensity, reach))
end

return spectrumBackground
