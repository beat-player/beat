-- The pieces a screen is made of. They take the app's theme and assets rather than owning either;
-- the app decides what a click means and the theme decides what everything looks like.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local names = require("beat.music.names")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local render = {}

---@param app beat.App
---@param size number
---@param onClick any
---@param isActive boolean?
---@param content wonderland.Element
---@return wonderland.Element
function render.iconSurface(app, size, onClick, isActive, content)
	local theme = app.services.appearance.theme

	return div()
	:style(sty():size(size, size):radius(theme:radius("full")):align("center"):justify("center"))
	:hover(sty():size(size, size):radius(theme:radius("full")):bg(theme:color("hover"))
	:align("center"):justify("center"))
	:onClick(onClick)
	:children({ content})
end

---@param app beat.App
---@param name string
---@param size number
---@param onClick any
---@param isActive boolean?
---@return wonderland.Element
function render.iconButton(app, name, size, onClick, isActive)
	local theme = app.services.appearance.theme
	local colour = isActive and theme:color("text") or theme:color("muted")

	local glyphSize = math.max(18, math.floor(size * 0.8 + 0.5))
	return render.iconSurface(app, size, onClick, isActive,
	ui.icons.element(name, glyphSize, colour))
end

--- Three dots, drawn rather than taken from the icon face: the face has no ellipsis, and a
--- text fallback would sit on the wrong baseline next to the other controls.
---@param app beat.App
---@param size number
---@param onClick any
---@param isActive boolean?
---@return wonderland.Element
function render.moreButton(app, size, onClick, isActive)
	local theme = app.services.appearance.theme
	local colour = isActive and theme:color("text") or theme:color("muted")

	return render.iconSurface(app, size, onClick, isActive,
	div():style(sty():size(size, size)):canvas(function(canvas)
		local radius = math.max(1.2, math.floor(size * 0.064))
		local y = math.floor(canvas.height / 2 - radius)
		for at = 0, 2 do
				local x = math.floor(canvas.width / 2 + (at - 1) * size * 0.21 - radius)
				canvas:rect(x, y, radius * 2, radius * 2, colour, radius)
			end
	end))
end

--- The equalizer has no behaviour yet, so this is only its mark: four static bars, quieter than
--- the playing indicator because nothing here is measuring audio.
---@param app beat.App
---@param size number
---@param onClick any
---@param isActive boolean?
---@return wonderland.Element
function render.equalizerButton(app, size, onClick, isActive)
	local theme = app.services.appearance.theme
	local colour = isActive and theme:color("text") or theme:color("muted")
	local inner = math.max(12, math.floor(size * 0.72 + 0.5))

	return render.iconSurface(app, size, onClick, isActive,
	div():style(sty():size(inner, inner)):canvas(function(canvas)
		local levels = { 0.36, 0.7, 0.48, 0.58}
		local barWidth = math.max(2, math.floor(inner * 0.1))
		local gap = math.max(2, math.floor((canvas.width - barWidth * #levels) / (#levels + 1)))
		for at, level in ipairs(levels) do
				local height = math.max(2, math.floor(canvas.height * level))
				local x = math.floor(gap + (at - 1) * (barWidth + gap))
				canvas:rect(x, canvas.height - height, barWidth, height, colour, barWidth / 2)
			end
	end))
end

---@param app beat.App
---@param label string
---@param onClick any
---@param opts { primary: boolean?, width: number?, height: number?, icon: string? }?
---@return wonderland.Element
function render.button(app, label, onClick, opts)
	opts = opts or {}
	local theme = app.services.appearance.theme
	local height = opts.height or theme:px(36)
	local colour = opts.primary and theme.accentInk or theme:color("text")
	local background = opts.primary and theme:color("accent") or theme:color("elevated")
	local hover = opts.primary and theme:color("accent", 0.86) or theme:color("hover")
	local gap = theme:px(6)

	local function base(fill)
		local style = sty()
		:h(height)
		:pad(0, theme:px(16), 0, theme:px(16))
		:row()
		:align("center")
		:justify("center")
		:gap(gap)
		:radius(theme:radius("sm"))
		:bg(fill)
		if opts.width ~= nil then style:w(opts.width) end
		return style
	end

	local children = {}
	if opts.icon ~= nil then
		children[#children + 1] = ui.icons.element(opts.icon, theme:px(16), colour)
	end
	children[#children + 1] = text(label):style(theme:s():text(theme:type("sm"))
	:weight("semibold"):fg(colour))

	return div()
	:style(base(background))
	:hover(base(hover))
	:onClick(onClick)
	:children(children)
end

---@param app beat.App
---@param album beat.Album
---@param size number
---@param radius number?
---@param glow boolean? # A soft halo in the picture's dominant colour
---@return wonderland.Element
function render.cover(app, album, size, radius, glow)
	local theme = app.services.appearance.theme
	-- The scan worker writes each cover into the local cache before its track events arrive, so
	-- decoding these files while the rest of the library is still being scanned is cheap. Covers
	-- fill in as albums appear instead of waiting for the scan to finish.
	local asset = app.services.covers:request(album, size)
	local style = sty():size(size, size):radius(radius or 8)

	if glow then
		-- The dominant colour is known once the picture has been decoded into the cache. On the
		-- first frame the cover is a placeholder, so the halo appears with the art.
		local colour = app.services.covers:colourOf(album)
		if colour ~= nil then
			local alpha = 0x66
			style:shadow(0, 0, math.max(12, math.floor(size * 0.24)), string.format("#%02x%02x%02x%02x",
			math.floor(colour.r * 255 + 0.5), math.floor(colour.g * 255 + 0.5),
			math.floor(colour.b * 255 + 0.5), alpha))
		end
	end

	if asset ~= nil then
		return div():style(style:image(asset.texture, asset.uv))
	end

	local initial = album.title:sub(1, 1):upper()

	return div()
	:style(style:align("center"):justify("center"):bg(theme:color("elevated")))
	:children(
	text(initial):style(theme:s():text(math.max(12, math.floor(size * 0.28))):weight("bold")
	:fg(theme:color("muted", 0.8)))
	)
end

--- The card's cover plus the title block beneath it. The block's height comes from the type it
--- sets, rather than a fixed guess: a type scale change must not cut an artist line in half.
---@param app beat.App
---@param width number
---@return number
function render.albumCardHeight(app, width)
	local theme = app.services.appearance.theme
	return width + theme:px(11) + theme:type("base") + theme:px(2) + theme:type("sm")
end

---@param app beat.App
---@param album beat.Album
---@param width number
---@param onOpen any
---@param onPlay any
---@return wonderland.Element
function render.albumCard(app, album, width, onOpen, onPlay)
	local theme = app.services.appearance.theme
	local current = app.services.playback:current()
	local thisAlbum = current ~= nil and current.albumId == album.id
	local playing = thisAlbum and app.services.playback.player:isPlaying()
	if thisAlbum then onPlay = { type = "togglePlay"} end

	local titleStyle = theme:s():w(width):text(theme:type("base")):weight("semibold"):fg(theme:color("text")):ellipsis()
	local artistStyle = theme:s():w(width):text(theme:type("sm")):weight("regular"):fg(theme:color("muted")):ellipsis()

	local height = render.albumCardHeight(app, width)
	return div()
	:style(sty():w(width):h(height):column())
	:hover(sty():w(width):h(height):column():bright(1.08))
	:onClick(onOpen)
	:onContextMenu(function(_, _, _, _, _, windowX, windowY)
		return { type = "open", overlay = "album_menu", id = album.id, x = windowX, y = windowY}
	end)
	:children({
	div():style(sty():size(width, width)):children({
	render.cover(app, album, width, theme:radius("md")),
	div()
	:style(sty():size(theme:px(36), theme:px(36)):radius(theme:radius("full"))
	:offset(width - theme:px(44), width - theme:px(44))
	:bg(theme:color("accent")):align("center"):justify("center"))
	:onClick(onPlay)
	:children(ui.icons.element(playing and "pause" or "play", theme:px(18), theme.accentInk)),
	}),
	div():style(sty():column():pad(theme:px(11), 0, 0, 0):gap(theme:px(2))):children({
	text(album.title):style(titleStyle),
	text(album.artist):style(artistStyle),
	}),
	})
end

---@param app beat.App
---@param playing boolean?
---@return wonderland.Element
function render.equalizer(app, playing)
	local theme = app.services.appearance.theme
	local colour = theme:color("accent")
	local now = wonderland.time.now()

	return div():style(sty():size(18, 18)):canvas(function(canvas)
		local bars = { 0.35, 0.75, 0.52}
		local width = canvas.width / 7
		for at = 1, 3 do
				local level = bars[at]
				if playing then
					level = 0.25 + 0.65 * (0.5 + 0.5 * math.sin(now * 7 + at * 1.7))
				end
				local height = math.max(2, math.floor(canvas.height * level))
				canvas:rect((at - 1) * width * 2 + width * 0.5, canvas.height - height, width, height,
				colour, width / 2)
			end
	end)
end

---@param app beat.App
---@param track beat.Track
---@param index number
---@param current boolean
---@param playing boolean
---@param onClick any
---@param width number?
---@param showAlbum boolean?
---@param titleOnly boolean? # The album page's table shows titles only; the header names the artist
---@return wonderland.Element
function render.trackRow(app, track, index, current, playing, onClick, width, showAlbum, titleOnly)
	local theme = app.services.appearance.theme
	if current then onClick = { type = "togglePlay"} end
	local titleColour = current and theme:color("accent") or theme:color("text")
	local muted = theme:color("muted")
	local rowBg = current and theme:color("accent", 0.07) or theme:color("surface", 0)
	local hoverBg = theme:color("hover")

	local marker
	if current then
		marker = render.equalizer(app, playing)
	else
		marker = text(tostring(index)):style(theme:s():text(theme:type("sm")):fg(theme:color("faint")))
	end

	width = width or theme:px(760)
	---@cast width number
	-- The album column is the first thing a phone cannot afford. Keeping the title and time
	-- legible is more useful than three columns squeezed into a narrow list.
	local albumColumn = showAlbum ~= false and width >= theme:px(520)
	local infoWidth = math.max(theme:px(100),
	width - (albumColumn and theme:px(324) or theme:px(122)))
	local info = {
	text(track.title):style(theme:s():w(infoWidth):text(theme:type("base")):weight("medium")
	:fg(titleColour):ellipsis()),
	}
	if not titleOnly then
		info[#info + 1] = text(track.artist):style(theme:s():w(infoWidth):text(theme:type("sm"))
		:fg(muted):ellipsis())
	end
	local children = {
	div():style(sty():w(24):align("center")):children(marker),
	div():style(sty():w(infoWidth):h(48):column():justify("center"):gap(1)):children(info),
	}

	if albumColumn then
		children[#children + 1] = div():style(sty():w(190):h(48):column():justify("center")):children(
		text(track.album):style(theme:s():w(190):text(theme:type("sm")):fg(muted):ellipsis())
		)
	end

	children[#children + 1] = div():style(sty():w(54):h(48):column():align("start"):justify("center")):children(
	text(names.clock(track.duration)):style(theme:s():text(theme:type("sm")):fg(muted))
	)

	return div()
	:style(sty():row():w(width):h(48):pad(0, theme:px(10), 0, theme:px(10)):gap(theme:px(12))
	:align("center"):radius(theme:radius("sm")):bg(rowBg))
	:hover(sty():row():w(width):h(48):pad(0, theme:px(10), 0, theme:px(10)):gap(theme:px(12))
	:align("center"):radius(theme:radius("sm")):bg(hoverBg))
	:onClick(onClick)
	:onContextMenu(function(_, _, _, _, _, windowX, windowY)
		return { type = "open", overlay = "track_menu", id = track.id, x = windowX, y = windowY}
	end)
	:children(children)
end

---@param app beat.App
---@param title string
---@param action any?
---@return wonderland.Element
function render.section(app, title, action)
	local theme = app.services.appearance.theme
	local children = {
	text(title):style(theme:s():text(theme:type("lg")):weight("bold"):fg(theme:color("text"))),
	}

	if action ~= nil then
		children[#children + 1] = text("See all"):style(theme:s():text(theme:type("sm")):weight("semibold")
		:fg(theme:color("muted"))):onClick(action)
	end

	return div():style(sty():row():wrel(1.0):h(theme:px(24)):align("end"):justify("space-between"))
	:children(children)
end

---@param app beat.App
---@param title string
---@param copy string?
---@param actionLabel string?
---@param action any?
---@param icon string? # An emoji or glyph instead of the drawn record
---@return wonderland.Element
function render.empty(app, title, copy, actionLabel, action, icon)
	local theme = app.services.appearance.theme

	local children = {}
	if icon ~= nil then
		children[#children + 1] = text(icon):style(theme:s():text(theme:px(40))
		:fg(theme:color("text")))
	else
		children[#children + 1] = div():style(sty():size(120, 120)):canvas(function(canvas)
			canvas:circle(canvas.width / 2, canvas.height / 2, canvas.width * 0.38,
			theme:color("elevated"))
			canvas:circle(canvas.width / 2, canvas.height / 2, canvas.width * 0.09,
			theme:color("accent", 0.55))
			for at = 0, 11 do
					local angle = at / 12 * math.pi * 2
					canvas:line(canvas.width / 2 + math.cos(angle) * canvas.width * 0.14,
					canvas.height / 2 + math.sin(angle) * canvas.height * 0.14,
					canvas.width / 2 + math.cos(angle) * canvas.width * 0.25,
					canvas.height / 2 + math.sin(angle) * canvas.height * 0.25,
					theme:px(2), theme:color("text", 0.08))
				end
		end)
	end
	children[#children + 1] = text(title):style(theme:s():text(theme:type("xl")):weight("bold")
	:fg(theme:color("text")))
	if copy ~= nil then
		local copyWidth = theme:px(420)
		if app.window ~= nil then
			copyWidth = math.min(copyWidth, app.window.width - theme:space(64))
		end
		children[#children + 1] = text(copy):style(theme:s():w(copyWidth):text(theme:type("sm"))
		:fg(theme:color("muted")):align("center"))
	end

	if actionLabel ~= nil and action ~= nil then
		children[#children + 1] = render.button(app, actionLabel, action,
		{ primary = true, width = theme:px(160)})
	end

	return div():style(sty():fill():column():align("center"):justify("center"):gap(theme:px(14)))
	:children(children)
end

--- A small FFT strip. The levels are already 0..1 and smoothed; this only places bars.
---@param app beat.App
---@param width number
---@param height number
---@param bands number?
---@return wonderland.Element
function render.spectrum(app, width, height, bands)
	local theme = app.services.appearance.theme
	local levels = app.services.playback.spectrum and app.services.playback.spectrum:values() or {}
	local count = math.min(bands or 32, #levels)
	local gap = theme:px(1)
	local barWidth = math.max(1, (width - gap * (count - 1)) / count)

	local active = false
	for at = 1, count do
			if (levels[at] or 0) > 0.01 then active = true; break end
		end

	return div():style(sty():w(width):h(height)):canvas(function(canvas)
		if not active then return end
		for at = 1, count do
				local level = levels[at] or 0
				local barHeight = math.max(1, math.floor(level * height))
				local x = (at - 1) * (barWidth + gap)
				canvas:rect(x, height - barHeight, barWidth, barHeight,
				theme:color("accent", 0.35 + level * 0.65), 1)
			end
	end)
end

---@class beat.ui.SliderOpts
---@field width number
---@field value number
---@field min number?
---@field max number?
---@field onchange fun(value: number): any
---@field trackColour string
---@field fillColour string
---@field thumbColour string?
---@field height number?
---@field trackHeight number?
---@field thumbSize number?

--- A slider drawn to a canvas: the part that moves is a shape, not a style. A style built from
--- the playhead is a new style every frame, which is what the style arena warns about.
---@param app beat.App
---@param opts beat.ui.SliderOpts
---@return wonderland.Element
function render.slider(app, opts)
	local theme = app.services.appearance.theme
	local height = opts.height or theme:px(18)
	local trackHeight = opts.trackHeight or theme:px(4)
	local thumbSize = opts.thumbSize or theme:px(14)
	local width = opts.width
	local min = opts.min or 0
	local max = opts.max or 1
	local span = max - min
	local value = span ~= 0 and (opts.value - min) / span or 0
	local fraction = math.max(0, math.min(1, value))
	local radius = trackHeight / 2
	local thumbColour = opts.thumbColour or opts.fillColour

	local slider = div():style(sty():w(width):h(height):row():align("center"))
	:slider({
	value = opts.value,
	min = min,
	max = max,
	onchange = opts.onchange,
	})
	-- The nub is a styled box, not a canvas polygon: the renderer antialiases rounded
	-- corners, while a small fan of triangles reads as a pixelated circle.
	:children(div():style(sty():size(thumbSize, thumbSize):radius(thumbSize / 2)
	:bg(thumbColour)):thumb())

	slider:canvas(function(canvas)
		local y = (canvas.height - trackHeight) / 2
		local track = math.max(0, canvas.width - thumbSize)
		local centre = fraction * track + thumbSize / 2

		canvas:rect(0, y, canvas.width, trackHeight, opts.trackColour, radius)
		if opts.origin == nil or opts.origin == 0 then
			canvas:rect(0, y, math.max(0, centre), trackHeight, opts.fillColour, radius)
		else
			local origin = opts.origin * track + thumbSize / 2
			if centre >= origin then
				canvas:rect(origin, y, centre - origin, trackHeight, opts.fillColour, radius)
			else
				canvas:rect(centre, y, origin - centre, trackHeight, opts.fillColour, radius)
			end
		end
	end)

	return slider
end

--- The spectrum as a quiet background for the playing bar. It is deliberately faint and wide:
--- content sits over it, so this is texture rather than a second meter.
---@param app beat.App
---@param canvas wonderland.Canvas
---@param opts { intensity: number?, reach: number? }?
function render.spectrumBackground(app, canvas, opts)
	opts = opts or {}
	local intensity = opts.intensity or 1
	local reach = opts.reach or 0.82
	local theme = app.services.appearance.theme
	local levels = app.services.playback.spectrum and app.services.playback.spectrum:values() or {}
	if #levels == 0 then return end

	local count = 72
	local gap = 3
	local barWidth = math.max(1, (canvas.width - gap * (count - 1)) / count)
	local active = false
	for at = 1, #levels do
			if levels[at] > 0.01 then active = true; break end
		end
	if not active then return end

	for at = 1, count do
			local position = (at - 1) / (count - 1) * (#levels - 1) + 1
			local lower = math.floor(position)
			local upper = math.min(#levels, lower + 1)
			local mix = position - lower
			local level = (levels[lower] or 0) * (1 - mix) + (levels[upper] or 0) * mix
			local barHeight = math.max(2, level * canvas.height * reach)
			local x = (at - 1) * (barWidth + gap)
			local alpha = (0.035 + level * 0.09) * intensity

			-- A wider, nearly transparent pass and a narrower core: at this opacity it reads as a
			-- blurred wash behind the bar rather than a row of hard rectangles.
			canvas:rect(x - 2, canvas.height - barHeight - 1, barWidth + 4, barHeight + 1,
			theme:color("accent", alpha * 0.35), 3)
			canvas:rect(x, canvas.height - barHeight, barWidth, barHeight,
			theme:color("accent", alpha), math.max(1, barWidth / 3))
		end
end

local BOTTOM_STRIP_SEGMENTS = 8

--- The outline of the bottom `height` pixels of a rounded box, as a convex polygon. The strip
--- follows the box's bottom corners even when the strip is shorter than the corner radius, which
--- is what makes it a border of the box rather than a line floating below it.
---@param width number
---@param height number
---@param radius number
---@return number[]
local function bottomStrip(width, height, radius)
	local r = math.min(radius, width / 2)
	if r <= 0 or height <= 0 then
		return { 0, 0, width, 0, width, height, 0, height}
	end

	local points = {}
	if height >= r then
		points[#points + 1] = 0
		points[#points + 1] = 0
		points[#points + 1] = width
		points[#points + 1] = 0
		points[#points + 1] = width
		points[#points + 1] = height - r

		for at = 1, BOTTOM_STRIP_SEGMENTS do
				local angle = at / BOTTOM_STRIP_SEGMENTS * math.pi / 2
				points[#points + 1] = width - r + math.cos(angle) * r
				points[#points + 1] = height - r + math.sin(angle) * r
			end

		points[#points + 1] = r
		points[#points + 1] = height

		for at = 1, BOTTOM_STRIP_SEGMENTS do
				local angle = math.pi / 2 + at / BOTTOM_STRIP_SEGMENTS * math.pi / 2
				points[#points + 1] = r + math.cos(angle) * r
				points[#points + 1] = height - r + math.sin(angle) * r
			end
	else
		local angle = math.asin((r - height) / r)
		local inset = r - math.cos(angle) * r
		points[#points + 1] = inset
		points[#points + 1] = 0
		points[#points + 1] = width - inset
		points[#points + 1] = 0

		for at = 1, BOTTOM_STRIP_SEGMENTS do
				local a = angle + (math.pi / 2 - angle) * at / BOTTOM_STRIP_SEGMENTS
				points[#points + 1] = width - r + math.cos(a) * r
				points[#points + 1] = height - r + math.sin(a) * r
			end

		points[#points + 1] = r
		points[#points + 1] = height

		for at = 1, BOTTOM_STRIP_SEGMENTS do
				local a = math.pi / 2 - (math.pi / 2 - angle) * at / BOTTOM_STRIP_SEGMENTS
				points[#points + 1] = r - math.cos(a) * r
				points[#points + 1] = height - r + math.sin(a) * r
			end
	end

	return points
end

--- Cut a convex polygon to the part with x <= `maxX`.
---@param points number[]
---@param maxX number
---@return number[]
local function clipAtX(points, maxX)
	local clipped = {}
	local count = math.floor(#points / 2)

	for at = 1, count do
			local x1, y1 = points[at * 2 - 1], points[at * 2]
			local nextAt = (at % count) + 1
			local x2, y2 = points[nextAt * 2 - 1], points[nextAt * 2]
			local inside1, inside2 = x1 <= maxX, x2 <= maxX

			if inside1 then
				clipped[#clipped + 1] = x1
				clipped[#clipped + 1] = y1
			end

			if inside1 ~= inside2 and x2 ~= x1 then
				local t = (maxX - x1) / (x2 - x1)
				clipped[#clipped + 1] = maxX
				clipped[#clipped + 1] = y1 + (y2 - y1) * t
			end
		end

	return clipped
end

--- A progress strip that is the bottom border of a rounded popup. The track spans the popup's
--- full width and its bottom corners follow the popup's radius; the fill is the same shape cut at
--- the progress width, so it never reads as a separate floating bar.
---@class beat.BottomBarOpts
---@field x number
---@field y number
---@field width number
---@field height number
---@field radius number
---@field fraction number
---@field trackColour string
---@field fillColour string

---@param canvas wonderland.Canvas
---@param opts beat.BottomBarOpts
function render.bottomBar(canvas, opts)
	if opts.width <= 0 or opts.height <= 0 then return end

	local points = bottomStrip(opts.width, opts.height, opts.radius)
	for at = 1, #points, 2 do
			points[at] = points[at] + opts.x
			points[at + 1] = points[at + 1] + opts.y
		end

	canvas:polygon(points, opts.trackColour)

	local value = math.max(0, math.min(1, opts.fraction))
	if value <= 0 then return end
	if value >= 1 then
		canvas:polygon(points, opts.fillColour)
		return
	end

	local clipped = clipAtX(points, opts.x + opts.width * value)
	if #clipped >= 6 then canvas:polygon(clipped, opts.fillColour) end
end

--- A bar whose fill follows a value, drawn to a canvas for the same reason as `render.slider`.
---@param width number
---@param height number
---@param fraction number
---@param trackColour string
---@param fillColour string
---@return wonderland.Element
function render.meter(width, height, fraction, trackColour, fillColour)
	local value = math.max(0, math.min(1, fraction))
	local radius = height / 2

	return div():style(sty():w(width):h(height)):canvas(function(canvas)
		canvas:rect(0, 0, canvas.width, canvas.height, trackColour, radius)
		canvas:rect(0, 0, canvas.width * value, canvas.height, fillColour, radius)
	end)
end

---@param width number
---@param height number
---@param rows number
---@param gap number
---@return number, number
function render.gridMetrics(width, height, rows, gap)
	local cell = math.floor((width - gap * (rows - 1)) / rows)
	return cell, cell
end


--- A named text field for a dialog. The text is a child of the input element rather than a
--- sibling drawn over it: the caret and a selection are placed from the run inside the field, so
--- text outside it leaves them at the field's origin with the wrong line height.
---@param app beat.App
---@param name string
---@param value string
---@param placeholder string
---@param oninput fun(value: string): any
---@param onsubmit fun(): any
---@param width number?
---@return wonderland.Element
function render.field(app, name, value, placeholder, oninput, onsubmit, width)
	local theme = app.services.appearance.theme
	local focused = app.layoutPlugin ~= nil and app.window ~= nil
	and app.layoutPlugin:getFocusedId(app.window) == name
	local shown = value ~= "" and value or (focused and " " or placeholder)
	local colour = value ~= "" and theme:color("text")
	or (focused and theme:color("text") or theme:color("faint"))
	local fieldStyle = sty():h(theme:px(34)):row():align("center")
	:pad(0, theme:px(10), 0, theme:px(10)):radius(theme:radius("sm")):bg(theme:color("surface"))
	:text(theme:type("sm")):fg(theme:color("text"))
	if width ~= nil then fieldStyle:w(width) else fieldStyle:wrel(1.0) end
	local field = div():style(fieldStyle)
	:input({
	name = name,
	value = value,
	oninput = oninput,
	onsubmit = onsubmit,
	})
	field:children(text(shown):style(theme:s():wrel(1.0):text(theme:type("sm")):fg(colour):ellipsis()))
	return field
end

--- Lay out tag pills in fixed columns. `action` is a function from a tag to the message its pill
--- sends, or nil for a read-only pill.
---@param app beat.App
---@param tags beat.Tag[]
---@param selected table<number, boolean>?
---@param action (fun(tag: beat.Tag): any)?
---@param width number
---@param columns number
---@param limit number?
---@return wonderland.Element?
function render.tagPills(app, tags, selected, action, width, columns, limit)
	if #tags == 0 then return nil end
	local theme = app.services.appearance.theme
	local gap = theme:px(8)
	local pillWidth = math.max(theme:px(80), math.floor((width - gap * (columns - 1)) / columns))
	local rows = {}
	local row = {}
	local shown = 0

	for _, tag in ipairs(tags) do
			if limit ~= nil and shown >= limit then break end
			local active = selected ~= nil and selected[tag.id] == true
			local fg = active and theme.accentInk or theme:color("text")
			local pill = div()
			:style(sty():w(pillWidth):h(theme:px(28)):pad(0, theme:px(10), 0, theme:px(10))
			:radius(theme:radius("full")):align("center"):justify("center")
			:bg(active and theme:color("accent") or theme:color("elevated"))
			:border(theme:px(1), active and theme:color("accent") or theme:color("border")))
			:children(text(tag.name):style(theme:s():w(pillWidth - theme:px(20)):text(theme:type("xs"))
			:weight("semibold"):fg(fg):ellipsis()))
			if action ~= nil then pill:onClick(action(tag)) end
			row[#row + 1] = pill
			shown = shown + 1
			if #row == columns then
				rows[#rows + 1] = div():style(sty():row():h(theme:px(28)):gap(gap)):children(row)
				row = {}
			end
		end

	if #row > 0 then rows[#rows + 1] = div():style(sty():row():h(theme:px(28)):gap(gap)):children(row) end
	if limit ~= nil and #tags > limit then
		rows[#rows + 1] = text("+" .. tostring(#tags - limit) .. " more tags"):style(
		theme:s():text(theme:type("xs")):fg(theme:color("faint"))
		)
	end
	if #rows == 0 then return nil end
	local height = #rows * theme:px(28) + math.max(0, #rows - 1) * theme:px(8)
	if limit ~= nil and #tags > limit then height = height + theme:px(18) end
	return div():style(sty():column():wrel(1.0):h(height):gap(theme:px(8))):children(rows)
end

--- How far a scan has got, from nothing to done.
---@param progress beat.ScanProgress
---@return number
function render.scanFraction(progress)
	if progress.files <= 0 then return 0 end
	return math.max(0, math.min(1, progress.inspected / progress.files))
end

---@param app beat.App
---@param track beat.Track
---@param player beat.Player
---@param width number
---@return wonderland.Element
function render.progress(app, track, player, width)
	local theme = app.services.appearance.theme
	local duration = track.duration > 0 and track.duration or player:duration()
	local position = player:position()
	local clockWidth = theme:px(34)
	local gap = theme:px(8)
	local trackWidth = width - clockWidth * 2 - gap * 2

	local function clock(value)
		return div():style(sty():w(clockWidth):h(theme:px(18)):row():align("center"):justify("center"))
		:children(text(names.clock(value)):style(theme:s():text(theme:type("xs"))
		:fg(theme:color("faint"))))
	end

	return div():style(sty():w(width):h(theme:px(18)):row():align("center"):gap(gap)):children({
	clock(position),
	render.slider(app, {
	width = trackWidth,
	value = position,
	min = 0,
	max = duration > 0 and duration or 1,
	onchange = function(value) return { type = "seek", seconds = value} end,
	trackColour = theme:color("text", 0.12),
	fillColour = theme:color("text"),
	thumbColour = theme:color("text"),
	}),
	clock(duration),
	})
end

---@param app beat.App
---@param width number
---@param trackWidth number? # The slider track, when it should line up with another slider's track
---@return wonderland.Element
function render.volume(app, width, trackWidth)
	local theme = app.services.appearance.theme
	local volume = app.services.settings.values.isMuted and 0 or app.services.settings.values.volume
	local iconSlot = trackWidth ~= nil and theme:px(34) or theme:px(22)
	local sliderWidth = trackWidth or (width - theme:px(30))

	return div():style(sty():w(width):h(theme:px(22)):row():align("center"):gap(theme:px(8))):children({
	div():style(sty():w(iconSlot):h(theme:px(22)):row():align("center"):justify("center")):children(
	render.iconButton(app, app.services.settings.values.isMuted and "mute" or "volume", theme:px(22),
	{ type = "mute"})
	),
	render.slider(app, {
	width = sliderWidth,
	value = volume,
	min = 0,
	max = 1,
	onchange = function(value) return { type = "volume", value = value} end,
	trackColour = theme:color("text", 0.12),
	fillColour = theme:color("muted"),
	thumbColour = theme:color("text"),
	thumbSize = theme:px(12),
	}),
	})
end

return render
