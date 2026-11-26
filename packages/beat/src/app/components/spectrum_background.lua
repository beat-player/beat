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

-- How many steps an alpha is quantised to. A canvas keeps a packed colour by the table it was
-- handed, so a table whose alpha is written again for each bar would draw the first bar's alpha on
-- every bar after it. Sixteen steps are under what the eye resolves at these opacities, and they
-- mean sixteen stable tables per shape for the whole strip.
local PALETTE_STEPS = 16

---@class beat.components.SpectrumPalette
---@field wash { r: number, g: number, b: number, a: number }[]
---@field core { r: number, g: number, b: number, a: number }[]
---@field baseAlpha number
---@field levelAlpha number
---@field maxAlpha number

--- The wash and core colours of a meter, made once per mode and intensity and then never written
--- again: every table handed to `canvas:rect` keeps one colour for as long as the theme lives, so
--- the canvas can pack it once. A new theme -- or a step of a crossfade -- has a new cache.
---@param theme beat.Theme
---@param meter beat.components.SpectrumMeter
---@param mobile boolean
---@param intensity number
---@return beat.components.SpectrumPalette
local function paletteFor(theme, meter, mobile, intensity)
	local palette = meter.palettes[mobile]
	if palette ~= nil then return palette end

	local accent = accentChannels(theme)
	local baseAlpha = mobile and MOBILE_ALPHA_FLOOR or ALPHA_FLOOR
	local levelAlpha = mobile and MOBILE_ALPHA_RANGE or ALPHA_RANGE
	local maxAlpha = (baseAlpha + levelAlpha) * intensity
	---@type { r: number, g: number, b: number, a: number }[]
	local wash = {}
	---@type { r: number, g: number, b: number, a: number }[]
	local core = {}
	for step = 0, PALETTE_STEPS - 1 do
		local alpha = maxAlpha * step / (PALETTE_STEPS - 1)
		wash[step] = { r = accent.r, g = accent.g, b = accent.b, a = alpha * 0.35 }
		core[step] = { r = accent.r, g = accent.g, b = accent.b, a = alpha }
	end
	palette = { wash = wash, core = core, baseAlpha = baseAlpha, levelAlpha = levelAlpha, maxAlpha = maxAlpha }
	meter.palettes[mobile] = palette
	return palette
end

-- The level of every bar a draw works out, filled by a pass of its own before the shapes are
-- drawn: a loop inside the draw loop is a root trace the compiler aborts on, so the levels are
-- computed flat first and read flat after. Draws run one at a time and every pass fills the whole
-- array before anything reads it, so one array serves every strip.
local BAR_LEVELS = {}

--- The strip, in the room the element was given. The levels are read here, when the shapes are
--- drawn, and not when the view was built: the service mutates the table it hands out, so a
--- repaint of the screen already built draws the meter as it is now. A strip that is silent draws
--- nothing, which is what the bar looked like before anything played.
---@param app beat.App
---@param canvas wonderland.Canvas
---@param theme beat.Theme
---@param meter beat.components.SpectrumMeter
---@param intensity number
---@param reach number
---@param bold boolean
local function drawMeter(app, canvas, theme, meter, intensity, reach, bold)
	local levels = meter.levels
	-- A flat scan rather than one that breaks: a loop left early is a root trace the compiler
	-- abandons. The strip is a few dozen bands, so reading them all costs nothing.
	local active = false
	for at = 1, #levels do
		active = active or levels[at] > 0.01
	end
	if not active then return end

	-- The phone breakpoint is the window's, read from the strip's own width so the same view is a
	-- phone or a desktop depending on the window it lands in.
	local mobile = metrics.mobile(app, canvas.width)
	local palette = paletteFor(theme, meter, mobile, intensity)
	local washColours, coreColours = palette.wash, palette.core
	local baseAlpha, levelAlpha, maxAlpha = palette.baseAlpha, palette.levelAlpha, palette.maxAlpha
	local count, gap, barWidth = barLayout(theme, canvas.width, mobile, bold)
	local bands = #levels
	local spread = math.max(1, count - 1)
	local height = canvas.height
	local barLevels = BAR_LEVELS

	-- Every bar's level first, in a flat pass: the drawing loop below holds no loop of its own,
	-- which is what the trace compiler needs. Each pass writes all `count` entries, so nothing
	-- from an earlier, wider strip is read back.
	if count < bands then
		-- Fewer bars than bands: a bar is the loudest of the bands it covers, so a hit in any of
		-- them moves it rather than falling between two sampled ones. Each band belongs to exactly
		-- one bar -- `ceil(band * count / bands)` -- so one pass over the bands fills them all.
		for at = 1, count do barLevels[at] = 0 end
		for band = 1, bands do
			local at = math.floor((band * count + bands - 1) / bands)
			local value = levels[band] or 0
			if value > barLevels[at] then barLevels[at] = value end
		end
	else
		for at = 1, count do
			local position = (at - 1) / spread * (bands - 1) + 1
			local lower = math.floor(position)
			local upper = math.min(bands, lower + 1)
			local mix = position - lower
			barLevels[at] = (levels[lower] or 0) * (1 - mix) + (levels[upper] or 0) * mix
		end
	end

	for at = 1, count do
		local level = barLevels[at]
		-- A bar under a percent of its height is a two-pixel smudge at the faintest alpha: nothing
		-- to see, and one rect fewer to pack on a quiet passage.
		if level > 0.01 then
			local step = math.floor((baseAlpha + level * levelAlpha) / maxAlpha * (PALETTE_STEPS - 1) + 0.5)
			if step > PALETTE_STEPS - 1 then step = PALETTE_STEPS - 1 end
			local barHeight = math.max(2, level * height * reach)
			local x = (at - 1) * (barWidth + gap)

			-- A wider, nearly transparent pass and a narrower core: at this opacity it reads as a
			-- blurred wash behind the bar rather than a row of hard rectangles. The colours are
			-- the palette's own tables, so a repaint packs the same colour instead of a new one.
			canvas:rect(x - 2, height - barHeight - 1, barWidth + 4, barHeight + 1, washColours[step], 3)
			canvas:rect(x, height - barHeight, barWidth, barHeight, coreColours[step], math.max(1, barWidth / 3))
		end
	end
end

--- The strip's draw, kept for the theme and what it is asked for rather than made for every
--- frame: the bar and the now-playing screen ask for it with their own intensity, and a closure
--- made in the view is one the trace compiler gives up on.
--- One strip a frame draws, as its draw, the levels it was made for, and the colours per mode.
---@class beat.components.SpectrumMeter
---@field levels number[]
---@field palettes table<boolean, beat.components.SpectrumPalette> # Colours, one palette per phone-or-desktop
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
		drawMeter(app, canvas, theme, meter, intensity, reach, bold)
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
		meter = { levels = levels, palettes = {} }
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
