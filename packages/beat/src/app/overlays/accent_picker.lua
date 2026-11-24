-- A custom accent picker: a saturation and brightness square over hue, saturation and brightness
-- sliders, opened by the Appearance section's Custom button.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local slider = require("beat.app.components.slider")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

-- How finely the square is drawn: enough cells that its corners read as a gradient rather than a
-- checkerboard, but few enough that a frame of it is a few hundred shapes.
local COLS, ROWS = 24, 16

-- What moving one channel asks for, one handler per channel rather than one per slider per frame.
---@type table<"h"|"s"|"v", fun(value: number): table>
local channelHandlers = {}

---@param field "h"|"s"|"v"
---@return fun(value: number): table
local function channelHandler(field)
	local handler = channelHandlers[field]
	if handler == nil then
		handler = function(value) return { type = "pickHsv", [field] = value } end
		channelHandlers[field] = handler
	end
	return handler
end

--- The colour a hue, saturation and brightness name, as the hex a style or a canvas draws.
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

--- Where a hex colour sits in the colour wheel, so the picker opens on the accent the app shows.
--- A colour it cannot read is the picker's default: a soft violet that reads on both themes.
---@param colour string
---@return number, number, number
local function rgbToHsv(colour)
	local hex = colour:match("^#(%x%x%x%x%x%x)$")
	if hex == nil then
		return 0.72, 0.55, 1
	end

	local r = (tonumber(hex:sub(1, 2), 16) or 0) / 255
	local g = (tonumber(hex:sub(3, 4), 16) or 0) / 255
	local b = (tonumber(hex:sub(5, 6), 16) or 0) / 255
	local maximum = math.max(r, g, b)
	local minimum = math.min(r, g, b)
	local delta = maximum - minimum
	local hue = 0
	if delta > 0 then
		if maximum == r then
			hue = ((g - b) / delta) % 6
		elseif maximum == g then
			hue = (b - r) / delta + 2
		else
			hue = (r - g) / delta + 4
		end
		hue = hue / 6
		if hue < 0 then
			hue = hue + 1
		end
	end

	local saturation = maximum > 0 ? delta / maximum : 0
	return hue, saturation, maximum
end

---@param value number
local function clamp01(value)
	return math.max(0, math.min(1, value))
end

---@class beat.AccentPickerState
---@field h number # Hue, from nought to one
---@field s number # Saturation, from nought to one
---@field v number # Brightness, from nought to one
---@field draft string

---@class beat.AccentPickerOverlay: beat.OverlaySurface
local accentPicker = {}

--- Opens on the accent the settings hold now: its colour when it is a custom one, the colour of its
--- name otherwise, so the picker starts where the app already is.
---@param app beat.App
function accentPicker.new(app)
	local accent = app.services.settings.values.accent
	local colour
	if type(accent) == "string" and accent:match("^#%x%x%x%x%x%x$") then
		colour = accent:lower()
	else
		colour = app.services.appearance:accentColour(type(accent) == "string" ? accent : "lime")
	end
	local h, s, v = rgbToHsv(colour)
	---@type beat.AccentPickerState
	return { h = h, s = s, v = v, draft = colour }
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.AccentPickerState>
---@param message beat.Message
function accentPicker.update(app, overlay, message)
	local state = overlay.state
	if message.type == "pickHsv" then
		local pick = message --[[@as { h: number?, s: number?, v: number? }]]
		if type(pick.h) == "number" then
			state.h = clamp01(pick.h)
		end
		if type(pick.s) == "number" then
			state.s = clamp01(pick.s)
		end
		if type(pick.v) == "number" then
			state.v = clamp01(pick.v)
		end
		state.draft = hsvColour(state.h, state.s, state.v)
		app:refresh()
	elseif message.type == "pickAccent" then
		local value = message.value
		if type(value) == "string" and value:match("^#%x%x%x%x%x%x$") then
			state.draft = value:lower()
			state.h, state.s, state.v = rgbToHsv(state.draft)
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

--- One labelled channel slider: the three are the same control with a different colour and a
--- different field on the message, so they are built the same way.
---@param app beat.App
---@param theme beat.Theme
---@param label string
---@param field "h"|"s"|"v"
---@param value number
---@param fillColour string
---@param sliderWidth number
---@param labelWidth number
---@param rowHeight number
---@param rowGap number
local function channelRow(app, theme, label, field, value, fillColour, sliderWidth, labelWidth, rowHeight, rowGap)
	return div()
		:style(sty():row():h(rowHeight):gap(rowGap):align("center"))
		:children(
			{
				text(label):style(
					theme:s():w(labelWidth):text(theme:type("sm")):weight("medium"):fg(theme:color("muted"))
				),
				slider.view(
					app,
					{
						width = sliderWidth,
						value = value,
						onchange = channelHandler(field),
						-- The three channels are the same size; the channel is what tells their
						-- draws apart.
						instance = field,
						trackColour = theme:color("text", 0.1),
						fillColour = fillColour,
						thumbColour = theme:color("text"),
						height = rowHeight,
						trackHeight = theme:px(6),
						thumbSize = theme:px(18)
					}
				)
			}
		)
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.AccentPickerState>
---@param window wonderland.RenderWindow
---@return wonderland.Element
function accentPicker.view(app, overlay, window)
	local state = overlay.state
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local h, s, v = state.h, state.s, state.v
	local draft = state.draft
	local pad = theme:px(18)
	local gap = theme:px(12)
	local titleHeight = theme:px(26)
	local previewHeight = theme:px(40)
	local squareHeight = theme:px(160)
	local sliderHeight = theme:px(28)
	local footerHeight = theme:px(32)
	local panelWidth = math.min(theme:px(360), window.width - theme:px(24))
	local inner = math.max(0, panelWidth - pad * 2)
	local labelWidth = theme:px(80)
	local rowGap = theme:px(10)
	local sliderWidth = math.max(0, inner - labelWidth - rowGap)
	local panelHeight = pad * 2 + titleHeight + previewHeight + squareHeight + sliderHeight * 3 + footerHeight + gap * 6

	-- The square is a grid of small rectangles rather than a shader: the canvas has no gradient, and
	-- a hue carried by the colour of each cell is what a saturation and brightness plane is.
	local square = div()
		:style(sty():w(inner):h(squareHeight):radius(theme:radius("md")))
		:canvas(
			function(canvas)
				local cellWidth = canvas.width / COLS
				local cellHeight = canvas.height / ROWS
				for row = 0, ROWS - 1 do
					local top = math.floor(row * cellHeight)
					local bottom = math.floor((row + 1) * cellHeight + 0.5)
					for column = 0, COLS - 1 do
						local left = math.floor(column * cellWidth)
						local right = math.floor((column + 1) * cellWidth + 0.5)
						canvas:rect(
							left,
							top,
							right - left,
							bottom - top,
							hsvColour(h, column / (COLS - 1), 1 - row / (ROWS - 1)),
							0
						)
					end
				end
				-- A white ring with the chosen colour inside it, so the marker reads on any part of
				-- the square rather than only on the half its own colour contrasts with.
				local markerX = s * canvas.width
				local markerY = (1 - v) * canvas.height
				canvas:circle(markerX, markerY, theme:px(7), "#ffffff")
				canvas:circle(markerX, markerY, theme:px(5), draft)
			end
		)
		:onMouseDown(
			function(x, y, elementWidth, elementHeight)
				return {
					type = "pickHsv",
					s = elementWidth > 0 ? clamp01(x / elementWidth) : 0,
					v = elementHeight > 0 ? clamp01(1 - y / elementHeight) : 0
				}
			end
		)

	local titleRow = div()
		:style(sty():row():h(titleHeight):align("center"))
		:children(
			{ text("Custom accent"):style(theme:s():text(theme:type("lg")):weight("bold"):fg(theme:color("text"))) }
		)
	local previewRow = div()
		:style(sty():row():h(previewHeight):gap(theme:px(12)):align("center"))
		:children(
			{
				div()
					:style(
						sty()
							:size(theme:px(40), theme:px(40)):radius(theme:radius("full")):bg(draft)
							:border(theme:px(1), theme:color("border"))
					),
				text(draft:upper()):style(
					theme:s():text(theme:type("base")):weight("semibold"):fg(theme:color("text"))
				)
			}
		)

	local panel = div()
		:style(
			sty()
				:w(panelWidth):h(panelHeight):column():pad(pad):gap(gap):radius(theme:radius("lg"))
				:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
				:shadow(0, theme:px(16), theme:px(42), "#00000080")
		):onClick({ type = "keep" })
		:children(
			{
				titleRow,
				previewRow,
				square,
				channelRow(
					app,
					theme,
					"Hue",
					"h",
					h,
					hsvColour(h, 1, 1),
					sliderWidth,
					labelWidth,
					sliderHeight,
					rowGap
				),
				channelRow(
					app,
					theme,
					"Saturation",
					"s",
					s,
					hsvColour(h, s, 1),
					sliderWidth,
					labelWidth,
					sliderHeight,
					rowGap
				),
				channelRow(
					app,
					theme,
					"Brightness",
					"v",
					v,
					hsvColour(h, s, v),
					sliderWidth,
					labelWidth,
					sliderHeight,
					rowGap
				),
				div()
					:style(sty():row():h(footerHeight):gap(theme:px(8)):align("center"):justify("end"))
					:children(
						{
							ui.button(
								ctx,
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
