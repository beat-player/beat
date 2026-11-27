-- The equalizer: the shape the bands make, drawn as one response curve over a dB grid, the
-- presets as a row of chips, a preamp fader and an imported profile under them, and a fader per
-- band. On a phone it is a sheet at the bottom of the screen, within reach of a thumb; on a
-- desktop a dialog. Which presets exist, what they hold, what the preamp and a profile mean and
-- what changing one does is the equalizer service's; this file draws them and sends what was
-- clicked.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local slider = require("beat.app.components.slider")
local metrics = require("beat.app.components.helpers.metrics")
local popup = require("beat.app.components.popup")
local platform = require("beat.platform")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

-- What moving one band asks for, one handler per band rather than one per fader per frame.
---@type table<number, fun(value: number): table>
local gainHandlers = {}

---@param band number
---@return fun(value: number): table
local function gainHandler(band)
	local handler = gainHandlers[band]
	if handler == nil then
		handler = function(value) return { type = "equalizerGain", band = band, value = value } end
		gainHandlers[band] = handler
	end
	return handler
end

-- The preamp fader lands on half-decibel steps: it is a level correction, not a band's shape, and
-- a value read back as "+3.5 dB" is what someone will compare against their headphones' spec.
local function preampHandler(value)
	return { type = "equalizerPreamp", value = math.floor((value or 0) * 2 + 0.5) / 2 }
end

---@class beat.EqualizerOverlayState
---@field importOpen boolean # Whether the two import choices are showing under the button

--- A dialog rather than a menu: the action messages the preset chips and faders send are the
--- equalizer service's to answer, so the panel must stay open while they pass through it.
---@type beat.OverlaySurface
local equalizer = {}

-- The motion key the import menu unfolds from. One menu is on the screen at a time, so the clock
-- key is a constant rather than one per opening.
local IMPORT_KEY = "equalizerImport"

---@return beat.EqualizerOverlayState
function equalizer.new()
	return { importOpen = false }
end

---@param app beat.App
---@param _overlay beat.OverlayInstance
function equalizer.close(app, _overlay)
	app:focusField(nil)
end

--- The button that opened the panel closes it rather than opening a second one. Preset actions
--- are messages the equalizer service answers; the panel does not know what they mean. The import
--- choices are this panel's own: the paste trigger reads the clipboard here, because the service
--- never sees the app's clipboard.
---@param app beat.App
---@param overlay beat.OverlayInstance<beat.EqualizerOverlayState>
---@param message beat.Message
function equalizer.update(app, overlay, message)
	local state = overlay.state

	if message.type == "toggleEqualizer" then
		app:close(overlay)
		return true
	end

	if message.type == "toggleEqualizerImport" then
		state.importOpen = not state.importOpen
		if state.importOpen then popup.open(app, IMPORT_KEY) end
		app:refresh()
		return true
	end

	if message.type == "equalizerPasteProfile" then
		local clipboard = app.clipboard
		local copied = clipboard ~= nil and clipboard:getText() or ""
		state.importOpen = false
		-- Queued through the app rather than called on the service: the equalizer's message is the
		-- same one a paste from a file picker's text would send, so the two arrive by one road.
		app:act({ type = "equalizerImportText", text = copied })
		app:refresh()
		return true
	end

	-- A profile arriving or leaving closes the choices, and the service answers the message below.
	if message.type == "equalizerImportFile" or message.type == "equalizerClearProfile" then
		if state.importOpen then
			state.importOpen = false
			app:refresh()
		end
		return false
	end

	-- Any other press inside the panel -- a preset, a fader, the backdrop -- puts the choices away
	-- before it does what it was for. `keep` is a press on the panel's own surface, which does
	-- nothing and so closes nothing.
	if state.importOpen and message.type ~= "keep" then
		state.importOpen = false
		app:refresh()
	end
	return false
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

--- Where a frequency sits across the curve, 0 at the lowest and 1 at the highest the response was
--- sampled at. The curve is logarithmic, as hearing is, so a decade takes the same width anywhere.
---@param frequency number
---@param minimum number
---@param maximum number
---@return number
local function curveFraction(frequency, minimum, maximum)
	if frequency <= minimum then return 0 end
	if frequency >= maximum then return 1 end
	return math.log(frequency / minimum) / math.log(maximum / minimum)
end

--- The bank's response over a grid: a line at 0 dB and at either limit, a faint rule under each
--- band, the area between the curve and 0 dB washed in the accent, and a point where each band
--- sits. The values are the summed filters' magnitudes, made when the equalizer changed; this
--- callback only maps them to pixels.
---@param theme beat.Theme
---@param values number[] # dB at evenly spaced log frequencies
---@param limit number # The largest gain either way
---@param frequencies number[] # Where the faders sit, for the rules and points
---@param minimum number
---@param maximum number
---@return fun(canvas: wonderland.Canvas)
local function responseCurve(theme, values, limit, frequencies, minimum, maximum)
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
		local count = #values
		if count < 2 then return end
		local function yOf(gain) return middle - math.max(-1, math.min(1, gain / limit)) * reach end

		canvas:rect(0, margin, width, 1, grid)
		canvas:rect(0, height - margin - 1, width, 1, grid)
		for _, frequency in ipairs(frequencies) do
			canvas:rect(math.floor(curveFraction(frequency, minimum, maximum) * width), margin, 1, height - margin * 2, grid)
		end
		canvas:rect(0, math.floor(middle), width, 1, zero)

		-- The curve, one segment per sample: the samples are already evenly spaced, so the segment
		-- across the whole width is each pair of neighbours.
		local span = width / (count - 1)
		local lastX, lastY = 0, yOf(values[1])
		for index = 2, count do
			local at = span * (index - 1)
			local y = yOf(values[index])
			local top = math.min(y, middle)
			canvas:rect(lastX, top, at - lastX, math.abs(y - middle), wash)
			canvas:line(lastX, lastY, at, y, weight, line)
			lastX, lastY = at, y
		end

		-- A point where each fader sits, at the response there rather than the fader's own gain:
		-- an imported shelf moves the curve under a band the person did not touch.
		local radius = theme:px(4)
		for _, frequency in ipairs(frequencies) do
			local position = curveFraction(frequency, minimum, maximum) * (count - 1) + 1
			local at = math.min(count - 1, math.floor(position))
			local t = position - at
			local gain = values[at] * (1 - t) + values[at + 1] * t
			local x, y = curveFraction(frequency, minimum, maximum) * width, yOf(gain)
			canvas:rect(x - radius, y - radius, radius * 2, radius * 2, dot, radius)
		end
	end
end

--- One label, a fader and its value, the row a band and the preamp both use. `instance` keeps two
--- sliders of the same size from sharing a draw.
---@param app beat.App
---@param theme beat.Theme
---@param opts {
--- label: string,
--- value: number,
--- minimum: number,
--- maximum: number,
--- origin: number,
--- onchange: fun(value: number): table,
--- instance: any,
--- rowHeight: number,
--- labelWidth: number,
--- valueWidth: number,
--- sliderWidth: number,
--- thumbSize: number,
--- }
---@return wonderland.Element
local function faderRow(app, theme, opts)
	local shown = math.floor(opts.value * 10 + 0.5) / 10
	local value = shown == 0 ? "0 dB" : string.format("%+.1f dB", shown)
	return div()
		:style(sty():row():wrel(1.0):h(opts.rowHeight):gap(theme:px(12)):align("center"))
		:children(
			{
				text(opts.label):style(
					theme:s():w(opts.labelWidth):text(theme:type("sm")):weight("medium"):fg(theme:color("muted")):ellipsis()
				),
				slider.view(
					app,
					{
						width = opts.sliderWidth,
						height = opts.rowHeight,
						value = opts.value,
						min = opts.minimum,
						max = opts.maximum,
						origin = opts.origin,
						onchange = opts.onchange,
						instance = opts.instance,
						trackColour = theme:color("text", 0.1),
						fillColour = theme:color("accent"),
						thumbColour = theme:color("text"),
						trackHeight = theme:px(4),
						thumbSize = opts.thumbSize
					}
				),
				text(value):style(
					theme:s():w(opts.valueWidth):text(theme:type("sm")):weight("semibold")
						:fg(shown == 0 ? (theme:color("faint")) : (theme:color("text")))
				)
			}
		)
end

--- A row in the import choices: the same glyph column and hover the app's menus use.
---@param app beat.App
---@param ctx beat.ui.Context
---@param icon string
---@param label string
---@param action beat.Message
---@param width number
---@param height number
---@return wonderland.Element
local function importEntry(app, ctx, icon, label, action, width, height)
	local theme = app.services.appearance.theme
	local function shape(fill)
		return sty():row():w(width):h(height):pad(0, theme:px(10), 0, theme:px(10)):gap(theme:px(8)):align("center")
			:radius(theme:radius("sm")):bg(fill)
	end
	return div()
		:style(shape(theme:color("elevated")))
		:hover(shape(theme:color("hover")))
		:onClick(action)
		:children(
			{
				ui.icon(ctx, { name = icon, size = theme:px(16), colour = theme:color("muted") }),
				text(label):style(theme:s():wrel(1.0):text(theme:type("sm")):weight("medium"):fg(theme:color("text")):ellipsis())
			}
		)
end

--- The imported profile's name in a chip with the close that drops it, so the panel says what is
--- playing underneath the faders without a second page.
---@param app beat.App
---@param ctx beat.ui.Context
---@param name string
---@param width number
---@param height number
---@return wonderland.Element
local function profileChip(app, ctx, name, width, height)
	local theme = app.services.appearance.theme
	local closeSize = theme:px(height - 4)
	local labelWidth = math.max(theme:px(24), width - theme:px(14) - closeSize - theme:px(4))
	return div()
		:style(
			sty():row():w(width):h(height):pad(0, theme:px(4), 0, theme:px(10)):gap(theme:px(4)):align("center")
				:radius(theme:radius("full")):bg(theme:color("accent", 0.1)):border(theme:px(1), theme:color("accent", 0.5))
		)
		:children(
			{
				text(name):style(
					theme:s():w(labelWidth):text(theme:type("xs")):weight("semibold"):fg(theme:color("accent")):ellipsis()
				),
				ui.iconButton(ctx, { name = "close", size = closeSize, onClick = { type = "equalizerClearProfile" } })
			}
		)
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.EqualizerOverlayState>
---@param window wonderland.RenderWindow
---@return wonderland.Element
function equalizer.view(app, overlay, window)
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local service = app.services.equalizer
	local state = overlay.state
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
			:canvas(
				responseCurve(
					theme,
					service:curve(),
					service.maximum,
					service.frequencies,
					service.curveMinimum,
					service.curveMaximum
				)
			),
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

	-- The import button and, when one is loaded, the profile it put under the faders. The button
	-- stays after an import so another profile can replace it; the chip's close is the way back.
	local profile = service:profile()
	local importWidth = theme:px(sheet and 152 or 142)
	local importOpen = state.importOpen
	local function importShape(fill)
		local border = importOpen ? (theme:color("accent", 0.7)) : (theme:color("border"))
		return sty()
			:row():w(importWidth):h(chipHeight):gap(theme:px(5)):align("center"):justify("center"):radius(theme:radius("full"))
			:bg(fill):border(theme:px(1), border)
	end
	local importRow = div()
		:style(sty():row():wrel(1.0):h(chipHeight):gap(chipGap):align("center"))
		:children(
			{
				div()
					:style(importShape(theme:color("surface"))):hover(importShape(theme:color("hover")))
					:onClick({ type = "toggleEqualizerImport" })
					:children(
						{
							ui.icon(ctx, { name = "folder", size = theme:px(14), colour = theme:color("muted") }),
							text("Import profile"):style(
								theme:s():text(theme:type("xs")):weight("semibold"):fg(theme:color("muted"))
							)
						}
					)
			}
		)
	if profile ~= nil then
		local profileWidth = math.max(theme:px(80), content - importWidth - chipGap)
		importRow:children({ profileChip(app, ctx, profile.name, profileWidth, chipHeight) })
	end
	add(importRow, chipHeight)

	-- The two ways a profile arrives, unfolded under the button that asks for one. A phone has the
	-- clipboard but not a system file dialog in this build, so only the paste is offered there.
	-- The menu gets a box of its own in the panel: the reveal clips the menu to how far it has
	-- come out, and the panel grows to hold it, so the faders below stay where they were and
	-- nothing is covered.
	if importOpen then
		local entries = {}
		if not platform.android then
			entries[#entries + 1] = { "folder", "Choose file…", { type = "equalizerImportFile" } }
		end
		entries[#entries + 1] = { "pencil", "Paste from clipboard", { type = "equalizerPasteProfile" } }

		local entryHeight = theme:px(36)
		local menuPadding = theme:px(6)
		local menuGap = theme:px(2)
		local menuHeight = menuPadding * 2 + #entries * entryHeight + (#entries - 1) * menuGap
		local menuRows = {}
		for _, entry in ipairs(entries) do
			menuRows[#menuRows + 1] = importEntry(app, ctx, entry[1], entry[2], entry[3], content - menuPadding * 2, entryHeight)
		end
		local menu = div()
			:style(
				sty():column():w(content):h(menuHeight):pad(menuPadding):gap(menuGap):radius(theme:radius("md"))
					:bg(theme:color("surface")):border(theme:px(1), theme:color("border"))
					:shadow(0, theme:px(12), theme:px(30), "#00000080")
			)
			:onClick({ type = "keep" }):children(menuRows)
		local box = div()
			:style(sty():w(content):h(menuHeight))
			:children(
				{
					popup.view(
						app,
						{ key = IMPORT_KEY, panel = menu, x = 0, y = 0, width = content, height = menuHeight, grows = "down" }
					)
				}
			)
		add(box, menuHeight)
	end

	-- The preamp sits directly over the bands it corrects: one fader, the same shape as theirs,
	-- from a cut that keeps a boosted profile from clipping to a little extra on a quiet track.
	local rowHeight = theme:px(compact and 28 or (sheet and 40 or 34))
	local labelWidth = theme:px(56)
	local valueWidth = theme:px(52)
	local sliderWidth = content - labelWidth - valueWidth - theme:px(12) * 2
	local preampRange = service.preampMaximum - service.preampMinimum
	local preamp = service:preamp()
	add(
		faderRow(
			app,
			theme,
			{
				label = "Preamp",
				value = preamp,
				minimum = service.preampMinimum,
				maximum = service.preampMaximum,
				origin = preampRange ~= 0 and (0 - service.preampMinimum) / preampRange or 0,
				onchange = preampHandler,
				instance = "preamp",
				rowHeight = rowHeight,
				labelWidth = labelWidth,
				valueWidth = valueWidth,
				sliderWidth = sliderWidth,
				thumbSize = theme:px(sheet and 18 or 14)
			}
		),
		rowHeight
	)

	-- A fader per band: the frequency, the fader drawn from 0 dB either way, and the gain.
	local bands = {}
	for at = 1, #service.frequencies do
		bands[#bands + 1] = faderRow(
			app,
			theme,
			{
				label = service.labels[at],
				value = gains[at] or 0,
				minimum = service.minimum,
				maximum = service.maximum,
				origin = 0.5,
				onchange = gainHandler(at),
				instance = at,
				rowHeight = rowHeight,
				labelWidth = labelWidth,
				valueWidth = valueWidth,
				sliderWidth = sliderWidth,
				thumbSize = theme:px(sheet and 18 or 14)
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
