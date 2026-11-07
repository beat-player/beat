-- The equalizer panel: preset shapes above five bands, each band a slider and a signed gain. It
-- is deliberately a panel rather than a permanent row of faders: the controls are a deliberate
-- adjustment, not something that should compete with the transport every frame. Which presets
-- exist, what they hold and what changing one means is the equalizer service's; this file draws
-- them and sends what was clicked.
local wonderland = require("wonderland")
local iconButton = require("beat.app.components.icon_button")
local slider = require("beat.app.components.slider")

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
function equalizer.update(app, overlay, message)
	if message.type ~= "toggleEqualizer" then return false end
	app:close(overlay)
	return true
end

---@param app beat.App
---@param preset beat.EqualizerPreset
---@param width number
---@param height number
---@return wonderland.Element
local function equalizerChip(app, preset, width, height)
	local theme = app.services.appearance.theme
	local selected = app.services.equalizer:selected() == preset.id
	local textColour = selected and theme.accentInk or theme:color("muted")
	local resting = selected and theme:color("accent") or theme:color("surface")
	local hover = selected and theme:color("accent", 0.86) or theme:color("hover")
	local chip = div()
	:style(sty():row():w(width):h(height):align("center"):justify("center")
	:radius(theme:radius("full")):bg(resting))
	:hover(sty():row():w(width):h(height):align("center"):justify("center")
	:radius(theme:radius("full")):bg(hover))
	:onClick({ type = "equalizerPreset", id = preset.id})
	:children(text(preset.name):style(theme:s():text(theme:type("xs")):weight("semibold")
	:fg(textColour):ellipsis()))
	if preset.custom then
		chip:onDoubleClick({ type = "editEqualizerPreset", name = preset.id})
	end
	return chip
end

---@param app beat.App
---@param _overlay beat.OverlayInstance
---@param window wonderland.RenderWindow
---@return wonderland.Element
function equalizer.view(app, _overlay, window)
	local theme = app.services.appearance.theme
	local service = app.services.equalizer
	local compact = window.height < theme:px(520)
	local width = math.min(theme:px(460), window.width - theme:px(24))
	local padding = compact and theme:px(10) or theme:px(18)
	local gap = compact and theme:px(6) or theme:px(8)
	local content = width - padding * 2
	local chipWidth = compact and theme:px(72) or theme:px(78)
	local chipHeight = compact and theme:px(22) or theme:px(24)
	local presets = service:presets()
	local columns = math.max(1, math.floor((content + gap) / (chipWidth + gap)))
	local presetRows = math.ceil(#presets / columns)
	local presetHeight = presetRows * chipHeight + (presetRows - 1) * gap
	local rowHeight = compact and theme:px(26) or theme:px(30)
	local bandGap = theme:px(3)
	local bandsHeight = #service.frequencies * rowHeight
	+(#service.frequencies - 1) * bandGap
	local headerHeight = compact and theme:px(22) or theme:px(24)
	local height = padding * 2 + headerHeight + gap + presetHeight + gap + bandsHeight
	local panels = {}

	local header = div():style(sty():row():wrel(1.0):h(headerHeight):align("center")
	:justify("space-between")):children({
	text("Equalizer"):style(theme:s():text(theme:type("md")):weight("bold")
	:fg(theme:color("text"))),
	div():style(sty():row():w(theme:px(24) * 2 + theme:px(4)):h(headerHeight)
	:gap(theme:px(4)):align("center")):children({
	iconButton.view(app, { name = "add", size = theme:px(24), onClick = { type = "newEqualizerPreset"} }),
	iconButton.view(app, { name = "close", size = theme:px(24), onClick = { type = "dismiss"} }),
	}),
	})
	panels[#panels + 1] = header

	for row = 1, presetRows do
			local children = {}
			for column = 1, columns do
					local at = (row - 1) * columns + column
					local preset = presets[at] --[[@as beat.EqualizerPreset?]]
					if preset ~= nil then
						children[#children + 1] = equalizerChip(app,
						preset --[[@as beat.EqualizerPreset]], chipWidth, chipHeight)
					end
				end
			panels[#panels + 1] = div():style(sty():row():wrel(1.0):h(chipHeight):gap(gap)
			:align("center")):children(children)
		end

	local labelWidth = theme:px(60)
	local valueWidth = theme:px(44)
	local sliderWidth = content - labelWidth - valueWidth - gap * 2
	local gains = service:gains()
	for at = 1, #service.frequencies do
		local band = at
		local gain = gains[at] or 0
		local shown = math.floor(gain + 0.5)
		local value = shown == 0 and "0 dB" or string.format("%+d dB", shown)
		panels[#panels + 1] = div():style(sty():row():wrel(1.0):h(rowHeight):gap(gap)
		:align("center")):children({
		text(service.labels[at]):style(theme:s():w(labelWidth):text(theme:type("xs"))
		:fg(theme:color("muted"))),
		slider.view(app, {
		width = sliderWidth,
		value = gain,
		min = service.minimum,
		max = service.maximum,
		origin = 0.5,
		onchange = function(value_) return { type = "equalizerGain", band = band, value = value_} end,
		trackColour = theme:color("text", 0.12),
		fillColour = theme:color("accent"),
		thumbColour = theme:color("text"),
		thumbSize = theme:px(12),
		}),
			text(value):style(theme:s():w(valueWidth):text(theme:type("xs"))
			:fg(theme:color("text"))),
			})
		end

	local panel = div()
	:style(sty():w(width):h(height):column():pad(padding):gap(gap)
	:radius(theme:radius("md")):bg(theme:color("elevated"))
	:border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(14), theme:px(36), "#00000099"))
	:onClick({ type = "keep"})
	:children(panels)

	return div()
	:style(sty():size(window.width, window.height):offset(0, 0):z(130)
	:column():align("center"):justify("center")
	:bg(theme:color("overlay"))):onClick({ type = "dismiss"})
	:children({ panel})
end

return equalizer
