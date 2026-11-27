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
local styleCache = require("beat.app.components.helpers.styles")
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

-- The panel's fixed messages: the same tables every frame the panel is drawn, rather than new ones
-- for each press it could send.
local NEW_PRESET = { type = "newEqualizerPreset" }
local TOGGLE_IMPORT = { type = "toggleEqualizerImport" }
local CLEAR_PROFILE = { type = "equalizerClearProfile" }
local IMPORT_FILE = { type = "equalizerImportFile" }
local IMPORT_PASTE = { type = "equalizerPasteProfile" }
local KEEP = { type = "keep" }
local DISMISS = { type = "dismiss" }

---@type { string, string, table }[]
local IMPORT_ENTRIES = platform.android
		and { { "pencil", "Paste from clipboard", IMPORT_PASTE } }
	or { { "folder", "Choose file…", IMPORT_FILE }, { "pencil", "Paste from clipboard", IMPORT_PASTE } }

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

--- The three builders a preset chip is: its resting fill, its hover fill and its label. They depend
--- on whether the chip is the selected shape and on the size it was measured at; the panel rebuilds
--- its chips on every frame, so each set is made once per theme and size.
---@class beat.EqualizerChipStyles
---@field base wonderland.StyleBuilder
---@field hover wonderland.StyleBuilder
---@field label wonderland.StyleBuilder

---@param theme beat.Theme
---@param selected boolean
---@param width number
---@param height number
---@return beat.EqualizerChipStyles
local function chipStyles(theme, selected, width, height)
	local byHeight = styleCache.of(theme, selected and "equalizerChipOn" or "equalizerChipOff", width)
	local record = byHeight[height] --[[@as beat.EqualizerChipStyles?]]
	if record ~= nil then return record end

	local radius = theme:radius("full")
	local border = selected and theme:color("accent", 0.7) or theme:color("border")
	record = {
		base = sty()
			:row():w(width):h(height):align("center"):justify("center"):radius(radius)
			:bg(selected and theme:color("accent", 0.14) or theme:color("surface")):border(theme:px(1), border),
		hover = sty()
			:row():w(width):h(height):align("center"):justify("center"):radius(radius)
			:bg(selected and theme:color("accent", 0.18) or theme:color("hover")):border(theme:px(1), border),
		label = theme:s():text(theme:type("xs")):weight("semibold"):fg(selected and theme:color("accent") or theme:color("muted"))
			:ellipsis()
	}
	byHeight[height] = record
	return record
end

-- A chip's press is the same message for the life of its preset, and a custom chip's double press
-- opens the dialog that names it: both are made once rather than once per frame.
---@type table<beat.EqualizerPreset, table>
local chipClicks = setmetatable({}, { __mode = "k" })
---@type table<beat.EqualizerPreset, table>
local chipEdits = setmetatable({}, { __mode = "k" })

---@param preset beat.EqualizerPreset
---@return table
local function chipClick(preset)
	local message = chipClicks[preset]
	if message == nil then
		message = { type = "equalizerPreset", id = preset.id }
		chipClicks[preset] = message
	end
	return message
end

---@param preset beat.EqualizerPreset
---@return table
local function chipEdit(preset)
	local message = chipEdits[preset]
	if message == nil then
		message = { type = "editEqualizerPreset", name = preset.id }
		chipEdits[preset] = message
	end
	return message
end

---@param app beat.App
---@param preset beat.EqualizerPreset
---@param width number
---@param height number
local function equalizerChip(app, preset, width, height)
	local theme = app.services.appearance.theme
	local selected = app.services.equalizer:selected() == preset.id
	local styles = chipStyles(theme, selected, width, height)
	local chip = div()
		:style(styles.base)
		:hover(styles.hover)
		:onClick(chipClick(preset))
		:children(text(preset.name):style(styles.label))
	if preset.custom then chip:onDoubleClick(chipEdit(preset)) end
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

--- The response draw, made when the bank or the theme changes rather than on every frame: the view
--- hands the same curve values until the equalizer is applied again.
---@type { theme: beat.Theme, values: number[], limit: number, frequencies: number[], minimum: number, maximum: number, draw: fun(canvas: wonderland.Canvas) }?
local curveCache

---@param theme beat.Theme
---@param values number[]
---@param limit number
---@param frequencies number[]
---@param minimum number
---@param maximum number
---@return fun(canvas: wonderland.Canvas)
local function curveDraw(theme, values, limit, frequencies, minimum, maximum)
	local kept = curveCache
	if
		kept == nil
		or kept.theme ~= theme
		or kept.values ~= values
		or kept.limit ~= limit
		or kept.frequencies ~= frequencies
		or kept.minimum ~= minimum
		or kept.maximum ~= maximum
	then
		kept = {
			theme = theme,
			values = values,
			limit = limit,
			frequencies = frequencies,
			minimum = minimum,
			maximum = maximum,
			draw = responseCurve(theme, values, limit, frequencies, minimum, maximum)
		}
		curveCache = kept
	end
	return kept.draw
end

-- The dB label a fader shows, by gain in tenths: the same string for the same tenth, so a drag
-- does not format one per frame. The gains and the preamp are clamped to a bounded range.
---@type table<number, string>
local dbLabels = {}

---@param value number
---@return string label
---@return boolean zero
local function dbText(value)
	local tenths = math.floor(value * 10 + 0.5)
	local label = dbLabels[tenths]
	if label == nil then
		label = tenths == 0 and "0 dB" or string.format("%+.1f dB", tenths / 10)
		dbLabels[tenths] = label
	end
	return label, tenths == 0
end

--- The faders' row and labels, and each band's slider props, kept for one content width and fader
--- height. The value is the one field written on each frame; everything else a slider reads is
--- fixed for that layout.
---@class beat.EqualizerFaderStyles
---@field rowHeight number
---@field thumbSize number
---@field sliderWidth number
---@field trackColour string
---@field fillColour string
---@field thumbColour string
---@field trackHeight number
---@field row wonderland.StyleBuilder
---@field label wonderland.StyleBuilder
---@field value wonderland.StyleBuilder
---@field zeroValue wonderland.StyleBuilder
---@field bands table<number, table>
---@field preamp table?

---@param theme beat.Theme
---@param content number
---@param rowHeight number
---@param thumbSize number
---@return beat.EqualizerFaderStyles
local function faderStyles(theme, content, rowHeight, thumbSize)
	local byHeight = styleCache.of(theme, "equalizerFaders", content)
	local record = byHeight[rowHeight] --[[@as beat.EqualizerFaderStyles?]]
	if record ~= nil and record.thumbSize == thumbSize then return record end

	local labelWidth = theme:px(56)
	local valueWidth = theme:px(52)
	record = {
		rowHeight = rowHeight,
		thumbSize = thumbSize,
		sliderWidth = content - labelWidth - valueWidth - theme:px(12) * 2,
		trackColour = theme:color("text", 0.1),
		fillColour = theme:color("accent"),
		thumbColour = theme:color("text"),
		trackHeight = theme:px(4),
		row = sty():row():wrel(1.0):h(rowHeight):gap(theme:px(12)):align("center"),
		label = theme:s():w(labelWidth):text(theme:type("sm")):weight("medium"):fg(theme:color("muted")):ellipsis(),
		value = theme:s():w(valueWidth):text(theme:type("sm")):weight("semibold"):fg(theme:color("text")),
		zeroValue = theme:s():w(valueWidth):text(theme:type("sm")):weight("semibold"):fg(theme:color("faint")),
		bands = {},
		preamp = nil
	}
	byHeight[rowHeight] = record
	return record
end

---@param app beat.App
---@param fader beat.EqualizerFaderStyles
---@param opts table # The slider's own props, kept for this fader
---@param label string
---@param valueText string
---@param zero boolean
---@return wonderland.Element
local function faderRow(app, fader, opts, label, valueText, zero)
	return div()
		:style(fader.row)
		:children({
			text(label):style(fader.label),
			slider.view(app, opts),
			text(valueText):style(zero and fader.zeroValue or fader.value)
		})
end

--- The shapes one import choice is drawn with, for its width and height.
---@class beat.EqualizerImportStyles
---@field base wonderland.StyleBuilder
---@field hover wonderland.StyleBuilder
---@field label wonderland.StyleBuilder
---@field row wonderland.StyleBuilder

---@param theme beat.Theme
---@param width number
---@param height number
---@return beat.EqualizerImportStyles
local function importEntryStyles(theme, width, height)
	local byHeight = styleCache.of(theme, "equalizerImportEntry", width)
	local record = byHeight[height] --[[@as beat.EqualizerImportStyles?]]
	if record ~= nil then return record end

	local radius = theme:radius("sm")
	record = {
		base = sty()
			:row():w(width):h(height):pad(0, theme:px(10), 0, theme:px(10)):gap(theme:px(8)):align("center")
			:radius(radius):bg(theme:color("elevated")),
		hover = sty()
			:row():w(width):h(height):pad(0, theme:px(10), 0, theme:px(10)):gap(theme:px(8)):align("center")
			:radius(radius):bg(theme:color("hover")),
		label = theme:s():wrel(1.0):text(theme:type("sm")):weight("medium"):fg(theme:color("text")):ellipsis(),
		row = sty():row():wrel(1.0):h(height):gap(theme:px(8)):align("center")
	}
	byHeight[height] = record
	return record
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
	local styles = importEntryStyles(theme, width, height)
	return div()
		:style(styles.base)
		:hover(styles.hover)
		:onClick(action)
		:children(
			{
				ui.icon(ctx, { name = icon, size = theme:px(16), colour = theme:color("muted") }),
				text(label):style(styles.label)
			}
		)
end

--- The chip the imported profile's name sits in, and the close that drops it. Its builder and the
--- label's width depend only on the room the chip was given.
---@class beat.EqualizerProfileStyles
---@field base wonderland.StyleBuilder
---@field label wonderland.StyleBuilder
---@field closeSize number

---@param theme beat.Theme
---@param width number
---@param height number
---@return beat.EqualizerProfileStyles
local function profileChipStyles(theme, width, height)
	local byHeight = styleCache.of(theme, "equalizerProfileChip", width)
	local record = byHeight[height] --[[@as beat.EqualizerProfileStyles?]]
	if record ~= nil then return record end

	local closeSize = theme:px(height - 4)
	local labelWidth = math.max(theme:px(24), width - theme:px(14) - closeSize - theme:px(4))
	record = {
		closeSize = closeSize,
		base = sty()
			:row():w(width):h(height):pad(0, theme:px(4), 0, theme:px(10)):gap(theme:px(4)):align("center")
			:radius(theme:radius("full")):bg(theme:color("accent", 0.1)):border(theme:px(1), theme:color("accent", 0.5)),
		label = theme:s():w(labelWidth):text(theme:type("xs")):weight("semibold"):fg(theme:color("accent")):ellipsis()
	}
	byHeight[height] = record
	return record
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
	local styles = profileChipStyles(theme, width, height)
	return div()
		:style(styles.base)
		:children(
			{
				text(name):style(styles.label),
				ui.iconButton(ctx, { name = "close", size = styles.closeSize, onClick = CLEAR_PROFILE })
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
	local height = padding * 2
	local panels = {}

	local headerHeight = theme:px(28)
	local titleSlot = styleCache.of(theme, "equalizerTitle", 0)
	local title = titleSlot[0]
	if title == nil then
		title = theme:s():text(theme:type("lg")):weight("bold"):fg(theme:color("text"))
		titleSlot[0] = title
	end
	local headerSlot = styleCache.of(theme, "equalizerHeader", headerHeight)
	local headerRow = headerSlot[0]
	if headerRow == nil then
		headerRow = sty():row():wrel(1.0):h(headerHeight):align("center"):justify("space-between")
		headerSlot[0] = headerRow
	end
	panels[#panels + 1] = div()
		:style(headerRow)
		:children({
			text("Equalizer"):style(title),
			ui.iconButton(ctx, { name = "close", size = theme:px(28), onClick = DISMISS })
		})
	height += headerHeight

	local gains = service:gains()
	local curveHeight = theme:px(compact and 72 or 112)
	local curveSlot = styleCache.of(theme, "equalizerCurve", content)
	local curveBox = curveSlot[curveHeight]
	if curveBox == nil then
		curveBox = sty():w(content):h(curveHeight):radius(theme:radius("md")):bg(theme:color("bg", 0.6))
		curveSlot[curveHeight] = curveBox
	end
	panels[#panels + 1] = div()
		:style(curveBox)
		:canvas(curveDraw(theme, service:curve(), service.maximum, service.frequencies, service.curveMinimum, service.curveMaximum))
	height += gap + curveHeight

	-- The presets wrap in rows of equal chips, and the last chip saves the bands as a new one.
	local presets = service:presets()
	local chipHeight = theme:px(sheet and 34 or 28)
	local chipGap = theme:px(8)
	local columns = math.max(3, math.min(4, math.floor((content + chipGap) / (theme:px(96) + chipGap))))
	local chipWidth = math.floor((content - chipGap * (columns - 1)) / columns)
	local cells = {}
	local presetCount = #presets
	for at = 1, presetCount do cells[#cells + 1] = equalizerChip(app, presets[at], chipWidth, chipHeight) end
	local saveSlot = styleCache.of(theme, "equalizerSave", chipWidth)
	local saveChip = saveSlot[chipHeight]
	if saveChip == nil then
		local radius = theme:radius("full")
		local border = theme:color("border")
		saveChip = {
			base = sty()
				:row():w(chipWidth):h(chipHeight):gap(theme:px(4)):align("center"):justify("center"):radius(radius)
				:bg(theme:color("surface")):border(theme:px(1), border),
			hover = sty()
				:row():w(chipWidth):h(chipHeight):gap(theme:px(4)):align("center"):justify("center"):radius(radius)
				:bg(theme:color("hover")):border(theme:px(1), border),
			label = theme:s():text(theme:type("xs")):weight("semibold"):fg(theme:color("muted"))
		}
		saveSlot[chipHeight] = saveChip
	end
	cells[#cells + 1] = div()
		:style(saveChip.base):hover(saveChip.hover)
		:onClick(NEW_PRESET)
		:children({
			ui.icon(ctx, { name = "add", size = theme:px(14), colour = theme:color("muted") }),
			text("Save"):style(saveChip.label)
		})
	local presetRows = math.ceil(#cells / columns)
	local rowSlot = styleCache.of(theme, "equalizerPresetRow", chipHeight)
	local rowStyle = rowSlot[chipGap]
	if rowStyle == nil then
		rowStyle = sty():row():wrel(1.0):h(chipHeight):gap(chipGap)
		rowSlot[chipGap] = rowStyle
	end
	local rows = {}
	for row = 1, presetRows do
		local rowChildren = {}
		for column = 1, columns do
			local cell = cells[(row - 1) * columns + column]
			if cell ~= nil then rowChildren[#rowChildren + 1] = cell end
		end
		rows[row] = div():style(rowStyle):children(rowChildren)
	end
	local presetsHeight = presetRows * chipHeight + (presetRows - 1) * chipGap
	local blockSlot = styleCache.of(theme, "equalizerPresetBlock", presetsHeight)
	local blockStyle = blockSlot[chipGap]
	if blockStyle == nil then
		blockStyle = sty():column():wrel(1.0):h(presetsHeight):gap(chipGap)
		blockSlot[chipGap] = blockStyle
	end
	panels[#panels + 1] = div():style(blockStyle):children(rows)
	height += gap + presetsHeight

	-- The import button and, when one is loaded, the profile it put under the faders. The button
	-- stays after an import so another profile can replace it; the chip's close is the way back.
	local profile = service:profile()
	local importWidth = theme:px(sheet and 152 or 142)
	local importOpen = state.importOpen
	local importStyles = importEntryStyles(theme, importWidth, chipHeight)
	local importChildren = {
		div()
			:style(importStyles.base):hover(importStyles.hover)
			:onClick(TOGGLE_IMPORT)
			:children({
				ui.icon(ctx, { name = "folder", size = theme:px(14), colour = theme:color("muted") }),
				text("Import profile"):style(importStyles.label)
			})
	}
	if profile ~= nil then
		local profileWidth = math.max(theme:px(80), content - importWidth - chipGap)
		importChildren[#importChildren + 1] = profileChip(app, ctx, profile.name, profileWidth, chipHeight)
	end
	panels[#panels + 1] = div():style(importStyles.row):children(importChildren)
	height += gap + chipHeight

	-- The two ways a profile arrives, unfolded under the button that asks for one. A phone has the
	-- clipboard but not a system file dialog in this build, so only the paste is offered there.
	-- The menu gets a box of its own in the panel: the reveal clips the menu to how far it has
	-- come out, and the panel grows to hold it, so the faders below stay where they were and
	-- nothing is covered.
	if importOpen then
		local entryHeight = theme:px(36)
		local menuPadding = theme:px(6)
		local menuGap = theme:px(2)
		local entryCount = #IMPORT_ENTRIES
		local menuHeight = menuPadding * 2 + entryCount * entryHeight + (entryCount - 1) * menuGap
		local menuRows = {}
		for at = 1, entryCount do
			local entry = IMPORT_ENTRIES[at]
			menuRows[at] = importEntry(app, ctx, entry[1], entry[2], entry[3], content - menuPadding * 2, entryHeight)
		end
		local menuSlot = styleCache.of(theme, "equalizerMenu", content)
		local menuStyle = menuSlot[menuHeight]
		if menuStyle == nil then
			menuStyle = sty()
				:column():w(content):h(menuHeight):pad(menuPadding):gap(menuGap):radius(theme:radius("md"))
				:bg(theme:color("surface")):border(theme:px(1), theme:color("border"))
				:shadow(0, theme:px(12), theme:px(30), "#00000080")
			menuSlot[menuHeight] = menuStyle
		end
		local menu = div():style(menuStyle):onClick(KEEP):children(menuRows)
		local boxSlot = styleCache.of(theme, "equalizerMenuBox", content)
		local boxStyle = boxSlot[menuHeight]
		if boxStyle == nil then
			boxStyle = sty():w(content):h(menuHeight)
			boxSlot[menuHeight] = boxStyle
		end
		panels[#panels + 1] = div()
			:style(boxStyle)
			:children({
				popup.view(
					app,
					{ key = IMPORT_KEY, panel = menu, x = 0, y = 0, width = content, height = menuHeight, grows = "down" }
				)
			})
		height += gap + menuHeight
	end

	-- The preamp sits directly over the bands it corrects: one fader, the same shape as theirs,
	-- from a cut that keeps a boosted profile from clipping to a little extra on a quiet track.
	local rowHeight = theme:px(compact and 28 or (sheet and 40 or 34))
	local thumbSize = theme:px(sheet and 18 or 14)
	local faders = faderStyles(theme, content, rowHeight, thumbSize)
	local preampRange = service.preampMaximum - service.preampMinimum
	local preampOpts = faders.preamp
	if preampOpts == nil then
		preampOpts = {
			width = faders.sliderWidth,
			height = rowHeight,
			value = 0,
			min = service.preampMinimum,
			max = service.preampMaximum,
			origin = preampRange ~= 0 and (0 - service.preampMinimum) / preampRange or 0,
			onchange = preampHandler,
			instance = "preamp",
			trackColour = faders.trackColour,
			fillColour = faders.fillColour,
			thumbColour = faders.thumbColour,
			trackHeight = faders.trackHeight,
			thumbSize = thumbSize
		}
		faders.preamp = preampOpts
	end
	preampOpts.value = service:preamp()
	local preampText, preampZero = dbText(preampOpts.value)
	panels[#panels + 1] = faderRow(app, faders, preampOpts, "Preamp", preampText, preampZero)
	height += gap + rowHeight

	-- A fader per band: the frequency, the fader drawn from 0 dB either way, and the gain.
	local bandRows = {}
	local bandCount = #service.frequencies
	for at = 1, bandCount do
		local opts = faders.bands[at]
		if opts == nil then
			opts = {
				width = faders.sliderWidth,
				height = rowHeight,
				value = 0,
				min = service.minimum,
				max = service.maximum,
				origin = 0.5,
				onchange = gainHandler(at),
				instance = at,
				trackColour = faders.trackColour,
				fillColour = faders.fillColour,
				thumbColour = faders.thumbColour,
				trackHeight = faders.trackHeight,
				thumbSize = thumbSize
			}
			faders.bands[at] = opts
		end
		local value = gains[at] or 0
		opts.value = value
		local valueText, zero = dbText(value)
		bandRows[at] = faderRow(app, faders, opts, service.labels[at], valueText, zero)
	end
	local bandsHeight = bandCount * rowHeight
	local bandsSlot = styleCache.of(theme, "equalizerBands", bandsHeight)
	local bandsStyle = bandsSlot[0]
	if bandsStyle == nil then
		bandsStyle = sty():column():wrel(1.0):h(bandsHeight)
		bandsSlot[0] = bandsStyle
	end
	panels[#panels + 1] = div():style(bandsStyle):children(bandRows)
	height += gap + bandsHeight

	-- On a phone the sheet also clears the gesture bar under it, and its bottom corners are pushed
	-- past the window's edge, so only its top is rounded.
	local _, inset = metrics.insets()
	local radius = theme:radius("lg")
	local under = sheet and (inset + radius) or 0
	local panelSlot = styleCache.of(theme, compact and "equalizerPanelCompact" or "equalizerPanel", width)
	local panelStyle = panelSlot[height + under]
	if panelStyle == nil then
		panelStyle = sty()
			:w(width):h(height + under):column():pad(padding, padding, padding + under, padding):gap(gap):radius(radius)
			:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
			:shadow(0, theme:px(14), theme:px(36), "#00000099")
		panelSlot[height + under] = panelStyle
	end
	local panel = div():style(panelStyle):onClick(KEEP):children(panels)
	if sheet then
		local sheetSlot = styleCache.of(theme, "equalizerSheet", width)
		local sheetStyle = sheetSlot[height + inset]
		if sheetStyle == nil then
			sheetStyle = sty():w(width):h(height + inset)
			sheetSlot[height + inset] = sheetStyle
		end
		panel = div():style(sheetStyle):children({ panel })
	end

	local overlaySlot = styleCache.of(theme, sheet and "equalizerOverlaySheet" or "equalizerOverlay", window.width)
	local overlayStyle = overlaySlot[window.height]
	if overlayStyle == nil then
		overlayStyle = sty()
			:size(window.width, window.height):offset(0, 0):z(130):column():align("center")
			:justify(sheet ? "end" : "center"):bg(theme:color("overlay"))
		overlaySlot[window.height] = overlayStyle
	end
	return div():style(overlayStyle):children({ panel })
end

return equalizer
