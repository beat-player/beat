-- The equalizer panel: preset shapes above five bands, each band a slider and a signed gain. It
-- is deliberately a panel rather than a permanent row of faders: the controls are a deliberate
-- adjustment, not something that should compete with the transport every frame.
local wonderland = require("wonderland")
local core = require("beat-core")
local render = require("beat.app.ui")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@type beat.OverlaySurface
local equalizer = { light = true}

--- The built-in shapes and the ones this person has saved, in the order the panel draws them.
---@param app beat.App
---@return beat.EqualizerPreset[]
function equalizer.presets(app)
	local list = {}
	for _, preset in ipairs(core.equalizer.presets) do list[#list + 1] = preset end
	for _, preset in ipairs(app.settings.equalizerCustomPresets) do
			list[#list + 1] = {
			id = preset.name,
			name = preset.name,
			gains = preset.gains,
			custom = true,
			}
		end
	return list
end

---@param app beat.App
---@param id string?
---@return beat.EqualizerPreset?
function equalizer.find(app, id)
	if id == nil then return nil end
	for _, preset in ipairs(equalizer.presets(app)) do
			if preset.id == id then return preset end
		end
	return nil
end

---@param app beat.App
---@return string
function equalizer.nextName(app)
	local used = {}
	for _, preset in ipairs(equalizer.presets(app)) do used[preset.name] = true end
	local name = "Custom"
	local number = 2
	while used[name] do
		name = "Custom " .. tostring(number)
		number = number + 1
	end
	return name
end

---@param app beat.App
---@param oldName string
---@param newName string
---@return boolean
function equalizer.nameFree(app, oldName, newName)
	for _, preset in ipairs(equalizer.presets(app)) do
			if preset.name == newName and preset.name ~= oldName then return false end
		end
	return true
end

function equalizer.new()
	return {}
end

---@param app beat.App
---@param _overlay beat.OverlayInstance
function equalizer.close(app, _overlay)
	app:focusField(nil)
end

function equalizer.update(app, overlay, message)
	local kind = message.type
	if kind == "toggleEqualizer" then
		-- The equalizer button closes what it opened rather than opening a second panel.
		app:close(overlay)
	elseif kind == "equalizerPreset" then
		local preset = equalizer.find(app, message.id)
		if preset ~= nil then
			app.settings.equalizerPreset = preset.id
			app.settings.equalizerGains = core.equalizer.copyGains(preset.gains)
			app.player:setEqualizer(core.equalizer.bands(app.settings.equalizerGains))
			app:markSettingsDirty()
			app:refresh()
		end
	elseif kind == "newEqualizerPreset" then
		if #app.settings.equalizerCustomPresets >= 8 then
			app:toast("That is enough custom presets for now", "error")
		else
			local name = equalizer.nextName(app)
			local gains = core.equalizer.copyGains(app.settings.equalizerGains)
			app.settings.equalizerCustomPresets[#app.settings.equalizerCustomPresets + 1] = {
			name = name,
			gains = gains,
			}
			app.settings.equalizerPreset = name
			app.player:setEqualizer(core.equalizer.bands(gains))
			app:markSettingsDirty()
			app:refresh()
		end
	elseif kind == "editEqualizerPreset" then
		local preset = equalizer.find(app, message.name)
		if preset ~= nil and preset.custom then app:open("equalizer_rename", { name = preset.name}) end
	elseif kind == "equalizerGain" then
		local band = message.band
		if type(band) == "number" and band >= 1 and band <= #core.equalizer.frequencies then
			local gains = core.equalizer.sanitize(app.settings.equalizerGains)
			gains[band] = core.equalizer.clamp(message.value or 0)
			local selected = equalizer.find(app, app.settings.equalizerPreset)
			if selected ~= nil and selected.custom then
				for _, preset in ipairs(app.settings.equalizerCustomPresets) do
						if preset.name == selected.id then preset.gains = core.equalizer.copyGains(gains) end
					end
			else
				app.settings.equalizerPreset = "custom"
			end
			app.settings.equalizerGains = gains
			app.player:setEqualizer(core.equalizer.bands(gains))
			app:markSettingsDirty()
			app:refresh()
		end
	else
		return false
	end
	return true
end

---@param app beat.App
---@param preset beat.EqualizerPreset
---@param width number
---@param height number
---@return wonderland.Element
local function equalizerChip(app, preset, width, height)
	local theme = app.theme
	local selected = app.settings.equalizerPreset == preset.id
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
	local theme = app.theme
	local compact = window.height < theme:px(520)
	local width = math.min(theme:px(460), window.width - theme:px(24))
	local padding = compact and theme:px(10) or theme:px(18)
	local gap = compact and theme:px(6) or theme:px(8)
	local content = width - padding * 2
	local chipWidth = compact and theme:px(72) or theme:px(78)
	local chipHeight = compact and theme:px(22) or theme:px(24)
	local presets = equalizer.presets(app)
	local columns = math.max(1, math.floor((content + gap) / (chipWidth + gap)))
	local presetRows = math.ceil(#presets / columns)
	local presetHeight = presetRows * chipHeight + (presetRows - 1) * gap
	local rowHeight = compact and theme:px(26) or theme:px(30)
	local bandGap = theme:px(3)
	local bandsHeight = #core.equalizer.frequencies * rowHeight
	+(#core.equalizer.frequencies - 1) * bandGap
	local headerHeight = compact and theme:px(22) or theme:px(24)
	local height = padding * 2 + headerHeight + gap + presetHeight + gap + bandsHeight
	local panels = {}

	local header = div():style(sty():row():wrel(1.0):h(headerHeight):align("center")
	:justify("space-between")):children({
	text("Equalizer"):style(theme:s():text(theme:type("md")):weight("bold")
	:fg(theme:color("text"))),
	div():style(sty():row():w(theme:px(24) * 2 + theme:px(4)):h(headerHeight)
	:gap(theme:px(4)):align("center")):children({
	render.iconButton(app, "add", theme:px(24), { type = "newEqualizerPreset"}),
	render.iconButton(app, "close", theme:px(24), { type = "dismiss"}),
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
	for at = 1, #core.equalizer.frequencies do
			local band = at
			local gain = app.settings.equalizerGains[at] or 0
			local shown = math.floor(gain + 0.5)
			local value = shown == 0 and "0 dB" or string.format("%+d dB", shown)
			panels[#panels + 1] = div():style(sty():row():wrel(1.0):h(rowHeight):gap(gap)
			:align("center")):children({
			text(core.equalizer.labels[at]):style(theme:s():w(labelWidth):text(theme:type("xs"))
			:fg(theme:color("muted"))),
			render.slider(app, {
			width = sliderWidth,
			value = gain,
			min = core.equalizer.minimum,
			max = core.equalizer.maximum,
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
