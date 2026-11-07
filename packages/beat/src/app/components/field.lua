-- A named text field for a dialog. The text is a child of the input element rather than a sibling
-- drawn over it: the caret and a selection are placed from the run inside the field, so text
-- outside it leaves them at the field's origin with the wrong line height.
local wonderland = require("wonderland")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local field = {}

---@class beat.components.FieldProps
---@field name string # The input's focus id
---@field value string
---@field placeholder string # Shown until there is a value, or while focused and empty
---@field oninput fun(value: string): any
---@field onsubmit fun(): any
---@field width number? # Default fills the room its parent gives it

---@param app beat.App
---@param props beat.components.FieldProps
---@return wonderland.Element
function field.view(app, props)
	local theme = app.services.appearance.theme
	local focused = app.layoutPlugin ~= nil and app.window ~= nil
	and app.layoutPlugin:getFocusedId(app.window) == props.name
	local shown = props.value ~= "" and props.value or (focused and " " or props.placeholder)
	local colour = props.value ~= "" and theme:color("text")
	or (focused and theme:color("text") or theme:color("faint"))
	local fieldStyle = sty():h(theme:px(34)):row():align("center")
	:pad(0, theme:px(10), 0, theme:px(10)):radius(theme:radius("sm")):bg(theme:color("surface"))
	:text(theme:type("sm")):fg(theme:color("text"))
	if props.width ~= nil then fieldStyle:w(props.width) else fieldStyle:wrel(1.0) end
	local input = div():style(fieldStyle)
	:input({
	name = props.name,
	value = props.value,
	oninput = props.oninput,
	onsubmit = props.onsubmit,
	})
	input:children(text(shown):style(theme:s():wrel(1.0):text(theme:type("sm")):fg(colour):ellipsis()))
	return input
end

return field
