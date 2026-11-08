-- A small confirmable colour grid, opened by the Appearance section's Custom button.
local wonderland = require("wonderland")
local icon = require("beat.app.components.icon")
local button = require("beat.app.components.button")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

--- A hue and brightness grid: the twelve hues of a colour wheel at three tones each.
---@param hue number # From nought to one
---@param saturation number
---@param value number
local function hsvColour(hue, saturation, value)
	local at = hue * 6
	local index = math.floor(at) % 6
	local fraction = at - math.floor(at)
	local p = value * (1 - saturation)
	local q = value * (1 - fraction * saturation)
	local t = value * (1 - (1 - fraction) * saturation)
	local r, g, b
	if index == 0 then
		r, g, b = value, t, p
	elseif index == 1 then
		r, g, b = q, value, p
	elseif index == 2 then
		r, g, b = p, value, t
	elseif index == 3 then
		r, g, b = p, q, value
	elseif index == 4 then
		r, g, b = t, p, value
	else
		r, g, b = value, p, q
	end
	return string.format("#%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

local ACCENT_GRID = {}
for tone = 1, 3 do
	for hue = 0, 11 do
		local saturation = tone == 1 and 0.45 or tone == 2 and 0.72 or 0.94
		local value = tone == 3 ? 0.72 : 1
		ACCENT_GRID[#ACCENT_GRID + 1] = hsvColour(hue / 12, saturation, value)
	end
end

---@class beat.AccentPickerState
---@field draft string

---@class beat.AccentPickerOverlay: beat.OverlaySurface
local accentPicker = {}

--- Opens on the accent settings hold now -- its colour when it is a custom one, the colour of its
--- name otherwise -- so the grid starts where the app already is.
---@param app beat.App
function accentPicker.new(app)
	local draft = app.services.settings.values.accent:match("#") and app.services.settings.values.accent or app.services.appearance:accentColour(
		app.services.settings.values.accent
	)
	---@type beat.AccentPickerState
	return { draft = draft }
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.AccentPickerState>
---@param message beat.Message
function accentPicker.update(app, overlay, message)
	local state = overlay.state
	if message.type == "pickAccent" then
		local value = message.value
		if type(value) == "string" and value:match("^#%x%x%x%x%x%x$") then
			state.draft = value:lower()
			app:refresh()
		end
	elseif message.type == "confirmAccent" then
		if state.draft ~= nil and state.draft:match("^#%x%x%x%x%x%x$") then
			app.services.settings.values.accent = state.draft
			app.services.appearance:change(false)
		end
		app:close(overlay)
	else
		return false
	end
	return true
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.AccentPickerState>
---@param window wonderland.RenderWindow
---@return wonderland.Element
function accentPicker.view(app, overlay, window)
	local state = overlay.state
	local theme = app.services.appearance.theme
	local draft = state.draft
	local narrow = window.width < 560
	local columns = narrow ? 6 : 12
	local rows = math.ceil(#ACCENT_GRID / columns)
	local swatch = (theme:px(narrow ? 24 : 26))
	local gap = (theme:px(narrow ? 6 : 8))
	local pad = theme:px(20)
	local headerHeight = theme:px(44)
	local footerHeight = theme:px(36)
	local gridWidth = columns * swatch + (columns - 1) * gap
	local gridHeight = rows * swatch + (rows - 1) * gap
	local panelWidth = gridWidth + pad * 2
	local panelHeight = pad * 2 + headerHeight + gridHeight + footerHeight + theme:px(24)

	local cells = {}
	for rowAt = 1, rows do
		local row = {}
		for columnAt = 1, columns do
			local colour = ACCENT_GRID[(rowAt - 1) * columns + columnAt]
			if colour ~= nil then
				local selected = draft:lower() == colour
				row[#row + 1] = div()
					:style(
						sty()
							:size(swatch, swatch):radius(theme:radius("sm")):bg(colour):align("center"):justify("center")
							:border(((theme:px(selected ? 2 : 1))), selected ? (theme:color("text")) : (theme:color("border")))
					):onClick({ type = "pickAccent", value = colour })
					:children(
						selected ? icon.view(
							app,
							{ name = "check", size = (theme:px(14)), colour = app.services.appearance:accentInk(colour) }
						) : div()
					)
			end
		end
		cells[#cells + 1] = div():style(sty():row():h(swatch):gap(gap)):children(row)
	end

	local name = text("Custom accent"):style(theme:s():text(theme:type("lg")):weight("bold"):fg(theme:color("text")))
	local hex = text(draft:upper()):style(theme:s():text(theme:type("xs")):fg(theme:color("muted")))
	local header = div()
		:style(sty():row():h(headerHeight):gap(theme:px(10)):align("center"))
		:children(
			{
				div()
					:style(
						sty()
							:size(theme:px(36), theme:px(36)):radius(theme:radius("full")):bg(draft)
							:border(theme:px(1), theme:color("border"))
					),
				div():style(sty():column():wrel(1.0):gap(theme:px(1))):children({ name, hex })
			}
		)

	local panel = div()
		:style(
			sty()
				:w(panelWidth):h(panelHeight):column():pad(pad):gap(theme:px(12)):radius(theme:radius("lg"))
				:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
				:shadow(0, theme:px(16), theme:px(42), "#00000080")
		):onClick({ type = "keep" })
		:children(
			{
				header,
				div():style(sty():column():h(gridHeight):gap(gap)):children(cells),
				div()
					:style(sty():row():h(footerHeight):gap(theme:px(8)):align("center"):justify("end"))
					:children(
						{
							button.view(
								app,
								{ label = "Cancel", onClick = { type = "dismiss" }, height = theme:px(32), width = theme:px(82) }
							),
							div()
								:style(
									sty()
										:row():w(theme:px(112)):h(theme:px(32)):radius(theme:radius("full")):bg(draft):align("center")
										:justify("center")
								):onClick({ type = "confirmAccent" })
								:children(
									text("Use colour")
										:style(theme:s():text(theme:type("sm")):weight("semibold"):fg(app.services.appearance:accentInk(draft)))
								)
						}
					)
			}
		)

	return div()
		:style(sty():fill():offset(0, 0):z(110):column():align("center"):justify("center"):bg(theme:color("overlay")))
		:onClick({ type = "dismiss" }):children({ panel })
end

return accentPicker
