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

-- The now-playing screen's strip is the meter itself rather than texture behind a control bar: a
-- dozen-odd thick columns on a phone, a few dozen on a desktop, each one a range of the spectrum
-- that is read at a glance.
local BOLD_BAR_WIDTH = 34
local BOLD_GAP = 7
local BOLD_MIN_COUNT = 8
local BOLD_MAX_COUNT = 40

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
---@param bold boolean
---@return number count
---@return number gap
---@return number barWidth
local function barLayout(theme, width, mobile, bold)
	local gap, least, fewest, most
	if bold then
		gap, least = theme:px(BOLD_GAP), theme:px(BOLD_BAR_WIDTH)
		fewest, most = BOLD_MIN_COUNT, BOLD_MAX_COUNT
	elseif mobile then
		gap, least = math.max(MOBILE_GAP, theme:px(MOBILE_GAP)), math.max(24, theme:px(MOBILE_BAR_WIDTH))
		fewest, most = MOBILE_MIN_COUNT, MAX_COUNT
	else
		gap, least = math.max(2, theme:px(2)), math.max(16, theme:px(8))
		fewest, most = MIN_COUNT, MAX_COUNT
	end
	local count = math.floor((width + gap) / (least + gap))

	if count < fewest then count = fewest end
	if count > most then count = most end

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
---@param bold boolean
local function drawMeter(app, canvas, theme, levels, intensity, reach, bold)
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
	-- The two shapes of a bar, kept as tables across the loop and across the frames: a canvas reads
	-- the colour when the shape is added to the frame, so only the alpha has to be set for each
	-- bar, and the tables themselves are the same ones the last frame drew with.
	---@type table<string, any>
	local cache = theme:cache()
	local wash = cache.spectrumWash --[[@as { r: number, g: number, b: number, a: number }?]]
	if wash == nil then
		local accent = accentChannels(theme)
		wash = { r = accent.r, g = accent.g, b = accent.b, a = 0 }
		cache.spectrumWash, cache.spectrumCore = wash, { r = accent.r, g = accent.g, b = accent.b, a = 0 }
	end
	local core = cache.spectrumCore --[[@as { r: number, g: number, b: number, a: number }]]
	local count, gap, barWidth = barLayout(theme, canvas.width, mobile, bold)
	local bands = #levels
	local spread = math.max(1, count - 1)

	for at = 1, count do
		local level
		if count < bands then
			-- Fewer bars than bands: a bar is the loudest of the bands it covers, so a hit in any
			-- of them moves it rather than falling between two sampled ones.
			local first = math.floor((at - 1) * bands / count) + 1
			local last = math.max(first, math.floor(at * bands / count))
			level = 0
			for band = first, last do
				if levels[band] > level then level = levels[band] end
			end
		else
			local position = (at - 1) / spread * (bands - 1) + 1
			local lower = math.floor(position)
			local upper = math.min(bands, lower + 1)
			local mix = position - lower
			level = (levels[lower] or 0) * (1 - mix) + (levels[upper] or 0) * mix
		end
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

--- The draw of one meter, made where the meter is made: it reads the levels from the record so a
--- strip handed different ones keeps the draw it was made with. A function declared in the view
--- itself is one the trace compiler closes an upvalue on for every frame; this one is made once
--- for each meter the theme keeps.
---@param app beat.App
---@param theme beat.Theme
---@param intensity number
---@param reach number
---@param bold boolean
---@param meter beat.components.SpectrumMeter
---@return fun(canvas: wonderland.Canvas)
local function meterDraw(app, theme, intensity, reach, bold, meter)
	return function(canvas)
		drawMeter(app, canvas, theme, meter.levels, intensity, reach, bold)
	end
end

---@param app beat.App
---@param theme beat.Theme
---@param levels number[]
---@param intensity number
---@param reach number
---@param bold boolean
---@return fun(canvas: wonderland.Canvas)
local function meterOf(app, theme, levels, intensity, reach, bold)
	---@type table<string, any>
	local cache = theme:cache()
	local key = bold and "spectrumMetersBold" or "spectrumMeters"
	local meters = cache[key] --[[@as table<number, table<number, beat.components.SpectrumMeter>>?]]
	if meters == nil then
		meters = {}
		cache[key] = meters
	end

	local byIntensity = meters[intensity]
	if byIntensity == nil then
		byIntensity = {}
		meters[intensity] = byIntensity
	end
	local meter = byIntensity[reach]
	if meter == nil then
		meter = { levels = levels }
		meter.draw = meterDraw(app, theme, intensity, reach, bold, meter)
		byIntensity[reach] = meter
	end

	-- The draw reads the levels from the record, so a strip handed a different table of them keeps
	-- the draw it was made with: a draw made inside the view is a closure closed in a block the
	-- trace compiler leaves the frame for, and that is a frame drawn interpreted.
	meter.levels = levels
	return meter.draw
end

---@class beat.components.SpectrumBackgroundProps
---@field intensity number? # Scales the wash's opacity; default 1
---@field reach number? # How much of the bar's height the tallest bar takes; default 0.82
---@field bold boolean? # Few thick columns: the meter as the screen's own, not texture behind a bar

-- What a strip with no props of its own is built from: the bar's two ask for this on every frame.
local DEFAULTS = {}

--- The element fills the box it is given and takes no room in it, so a caller can place it as a
--- layer behind its siblings.
---@param app beat.App
---@param props beat.components.SpectrumBackgroundProps?
---@return wonderland.Element
function spectrumBackground.view(app, props)
	props = props or DEFAULTS
	local intensity = props.intensity or 1
	local reach = props.reach or 0.82
	local bold = props.bold == true
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

	return div():style(style):canvas(meterOf(app, theme, levels, intensity, reach, bold))
end

return spectrumBackground
