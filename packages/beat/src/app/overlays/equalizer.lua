-- The equalizer: the shape the five bands make, drawn as one response curve over a dB grid, the
-- presets as a row of chips, and a fader per band under it. On a phone it is a sheet at the bottom
-- of the screen, within reach of a thumb; on a desktop a dialog. Which presets exist, what they
-- hold and what changing one means is the equalizer service's; this file draws them and sends
-- what was clicked.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local slider = require("beat.app.components.slider")
local metrics = require("beat.app.components.helpers.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

--- A dialog rather than a menu: the action messages the preset chips and faders send are the
--- equalizer service's to answer, so the panel must stay open while they pass through it.
---@type beat.OverlaySurface
local equalizer = {}

function equalizer.new()
	return {}
end

---@param app beat.App
---@param _overlay beat.OverlayInstance
function equalizer.close(app, _overlay)
	app:focusField(nil)
end

--- The button that opened the panel closes it rather than opening a second one. Preset actions
--- are messages the equalizer service answers; the panel does not know what they mean.
---@param app beat.App
---@param overlay beat.OverlayInstance
---@param message beat.Message
function equalizer.update(app, overlay, message)
	if message.type ~= "toggleEqualizer" then return false end
	app:close(overlay)
	return true
end

---@param app beat.App
---@param preset beat.EqualizerPreset
---@param width number
---@param height number
local function equalizerChip(app, preset, width, height)
	local theme = app.services.appearance.theme
	local selected = app.services.equalizer:selected() == preset.id
	local textColour = selected ? (theme:color("accent")) : (theme:color("muted"))
	local function shape(fill)
		return sty()
			:row():w(width):h(height):align("center"):justify("center"):radius(theme:radius("full")):bg(fill)
			:border(theme:px(1), selected ? (theme:color("accent", 0.7)) : (theme:color("border")))
	end
	local chip = div()
		:style(shape(selected ? (theme:color("accent", 0.14)) : (theme:color("surface"))))
		:hover(shape(selected ? (theme:color("accent", 0.18)) : (theme:color("hover"))))
		:onClick({ type = "equalizerPreset", id = preset.id })
		:children(text(preset.name):style(theme:s():text(theme:type("xs")):weight("semibold"):fg(textColour):ellipsis()))
	if preset.custom then
		chip:onDoubleClick({ type = "editEqualizerPreset", name = preset.id })
	end
	return chip
end

--- The bands' gains as one smooth curve over a grid: a line at 0 dB and at either limit, a faint
--- rule under each band, the area between the curve and 0 dB washed in the accent, and a point
--- where each band sits. Catmull-Rom through the bands is what makes five numbers read as a sound.
---@param theme beat.Theme
---@param gains number[]
---@param limit number # The largest gain either way
---@return fun(canvas: wonderland.Canvas)
local function responseCurve(theme, gains, limit)
	local grid = theme:color("text", 0.08)
	local zero = theme:color("text", 0.16)
	local wash = theme:color("accent", 0.16)
	local line = theme:color("accent")
	local dot = theme:color("text")
	local weight = math.max(1.5, theme:px(2))
	return function(canvas)
		local width, height = canvas.width, canvas.height
		local margin = theme:px(10)
		local middle = height / 2
		local reach = middle - margin
		local count = #gains
		local function xOf(band) return (band - 0.5) / count * width end
		local function yOf(gain) return middle - math.max(-1, math.min(1, gain / limit)) * reach end

		canvas:rect(0, margin, width, 1, grid)
		canvas:rect(0, height - margin - 1, width, 1, grid)
		for band = 1, count do canvas:rect(math.floor(xOf(band)), margin, 1, height - margin * 2, grid) end
		canvas:rect(0, math.floor(middle), width, 1, zero)

		-- The curve, sampled across the whole width; outside the first and last band it carries on
		-- level, as a shelf does.
		local function gainAt(x)
			local position = x / width * count + 0.5
			if position <= 1 then return gains[1] or 0 end
			if position >= count then return gains[count] or 0 end
			local at = math.floor(position)
			local t = position - at
			local p0, p1 = gains[math.max(1, at - 1)], gains[at]
			local p2, p3 = gains[at + 1], gains[math.min(count, at + 2)]
			local t2, t3 = t * t, t * t * t
			return 0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (3 * p1 - p0 - 3 * p2 + p3) * t3)
		end

		local step = math.max(2, math.floor(width / 96))
		local lastX, lastY = 0, yOf(gainAt(0))
		for x = step, width + step - 1, step do
			local at = math.min(x, width)
			local y = yOf(gainAt(at))
			local top = math.min(y, middle)
			canvas:rect(lastX, top, at - lastX, math.abs(y - middle), wash)
			canvas:line(lastX, lastY, at, y, weight, line)
			lastX, lastY = at, y
		end

		local radius = theme:px(4)
		for band = 1, count do
			local x, y = xOf(band), yOf(gains[band] or 0)
			canvas:rect(x - radius, y - radius, radius * 2, radius * 2, dot, radius)
		end
	end
end

---@param app beat.App
---@param _overlay beat.OverlayInstance
---@param window wonderland.RenderWindow
---@return wonderland.Element
function equalizer.view(app, _overlay, window)
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local service = app.services.equalizer
	local sheet = ctx.mobile
	local compact = window.height < theme:px(520)
	local width = sheet and window.width or math.min(theme:px(480), window.width - theme:px(24))
	local padding = theme:px(compact and 12 or 20)
	local gap = theme:px(compact and 10 or 16)
	local content = width - padding * 2

	local panels = {}
	local height = padding * 2
	local function add(element, elementHeight)
		if #panels > 0 then height += gap end
		panels[#panels + 1] = element
		height += elementHeight
	end

	local headerHeight = theme:px(28)
	add(
		div()
			:style(sty():row():wrel(1.0):h(headerHeight):align("center"):justify("space-between"))
			:children(
				{
					text("Equalizer"):style(theme:s():text(theme:type("lg")):weight("bold"):fg(theme:color("text"))),
					ui.iconButton(ctx, { name = "close", size = theme:px(28), onClick = { type = "dismiss" } })
				}
			),
		headerHeight
	)

	local gains = service:gains()
	local curveHeight = theme:px(compact and 72 or 112)
	add(
		div()
			:style(sty():w(content):h(curveHeight):radius(theme:radius("md")):bg(theme:color("bg", 0.6)))
			:canvas(responseCurve(theme, gains, service.maximum)),
		curveHeight
	)

	-- The presets wrap in rows of equal chips, and the last chip saves the bands as a new one.
	local presets = service:presets()
	local chipHeight = theme:px(sheet and 34 or 28)
	local chipGap = theme:px(8)
	local columns = math.max(3, math.min(4, math.floor((content + chipGap) / (theme:px(96) + chipGap))))
	local chipWidth = math.floor((content - chipGap * (columns - 1)) / columns)
	local cells = {}
	for _, preset in ipairs(presets) do cells[#cells + 1] = equalizerChip(app, preset, chipWidth, chipHeight) end
	local function saveShape(fill)
		return sty()
			:row():w(chipWidth):h(chipHeight):gap(theme:px(4)):align("center"):justify("center"):radius(theme:radius("full"))
			:bg(fill):border(theme:px(1), theme:color("border"))
	end
	cells[#cells + 1] = div()
		:style(saveShape(theme:color("surface"))):hover(saveShape(theme:color("hover")))
		:onClick({ type = "newEqualizerPreset" })
		:children(
			{
				ui.icon(ctx, { name = "add", size = theme:px(14), colour = theme:color("muted") }),
				text("Save"):style(theme:s():text(theme:type("xs")):weight("semibold"):fg(theme:color("muted")))
			}
		)
	local presetRows = math.ceil(#cells / columns)
	local rows = {}
	for row = 1, presetRows do
		local children = {}
		for column = 1, columns do
			local cell = cells[(row - 1) * columns + column]
			if cell ~= nil then children[#children + 1] = cell end
		end
		rows[row] = div():style(sty():row():wrel(1.0):h(chipHeight):gap(chipGap)):children(children)
	end
	-- The rows sit a chip gap apart rather than a section gap, so the presets read as one block.
	local presetsHeight = presetRows * chipHeight + (presetRows - 1) * chipGap
	add(div():style(sty():column():wrel(1.0):h(presetsHeight):gap(chipGap)):children(rows), presetsHeight)

	-- A fader per band: the frequency, the fader drawn from 0 dB either way, and the gain.
	local rowHeight = theme:px(compact and 28 or (sheet and 40 or 34))
	local labelWidth = theme:px(56)
	local valueWidth = theme:px(52)
	local sliderWidth = content - labelWidth - valueWidth - theme:px(12) * 2
	local bands = {}
	for at = 1, #service.frequencies do
		local band = at
		local gain = gains[at] or 0
		local shown = math.floor(gain * 10 + 0.5) / 10
		local value = shown == 0 ? "0 dB" : string.format("%+.1f dB", shown)
		bands[#bands + 1] = div()
			:style(sty():row():wrel(1.0):h(rowHeight):gap(theme:px(12)):align("center"))
			:children(
				{
					text(service.labels[at]):style(theme:s():w(labelWidth):text(theme:type("sm")):weight("medium"):fg(theme:color("muted"))),
					slider.view(
						app,
						{
							width = sliderWidth,
							height = rowHeight,
							value = gain,
							min = service.minimum,
							max = service.maximum,
							origin = 0.5,
							onchange = |value_| -> { type = "equalizerGain", band = band, value = value_ },
							trackColour = theme:color("text", 0.1),
							fillColour = theme:color("accent"),
							thumbColour = theme:color("text"),
							trackHeight = theme:px(4),
							thumbSize = theme:px(sheet and 18 or 14)
						}
					),
					text(value):style(
						theme:s():w(valueWidth):text(theme:type("sm")):weight("semibold")
							:fg(shown == 0 ? (theme:color("faint")) : (theme:color("text")))
					)
				}
			)
	end
	local bandsHeight = #bands * rowHeight
	add(div():style(sty():column():wrel(1.0):h(bandsHeight)):children(bands), bandsHeight)

	-- On a phone the sheet also clears the gesture bar under it, and its bottom corners are pushed
	-- past the window's edge, so only its top is rounded.
	local _, inset = metrics.insets()
	local radius = theme:radius("lg")
	local under = sheet and (inset + radius) or 0
	local panel = div()
		:style(
			sty()
				:w(width):h(height + under):column():pad(padding, padding, padding + under, padding):gap(gap):radius(radius)
				:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
				:shadow(0, theme:px(14), theme:px(36), "#00000099")
		):onClick({ type = "keep" }):children(panels)
	if sheet then panel = div():style(sty():w(width):h(height + inset)):children({ panel }) end

	return div()
		:style(
			sty()
				:size(window.width, window.height):offset(0, 0):z(130):column():align("center")
				:justify(sheet ? "end" : "center"):bg(theme:color("overlay"))
		):onClick({ type = "dismiss" }):children({ panel })
end

return equalizer
