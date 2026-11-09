-- A named text field for a dialog. The text is a child of the input element rather than a sibling
-- drawn over it: the caret and a selection are placed from the run inside the field, so text
-- outside it leaves them at the field's origin with the wrong line height.
local wonderland = require("wonderland")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local field = {}

---@class beat.ui.FieldProps
---@field name string # The input's focus id
---@field value string
---@field placeholder string # Shown until there is a value, or while focused and empty
---@field oninput fun(value: string): any
---@field onsubmit fun(): any
---@field width number? # Default fills the room its parent gives it

---@param ctx beat.ui.Context
---@param props beat.ui.FieldProps
---@return wonderland.Element
function field.view(ctx, props)
	local focused = ctx:focused(props.name)
	local shown = props.value ~= "" and props.value or (focused and " " or props.placeholder)
	local colour = props.value ~= "" ? (ctx:color("text")) : focused and (ctx:color("text")) or (ctx:color("faint"))
	-- An inset well: darker than whatever it sits on and edged with a hairline, so the box is the
	-- same on a page, on a card (whose fill is `surface`) and on a dialog (whose fill is `elevated`).
	local fieldStyle = sty()
		:h(ctx:px(34)):row():align("center"):pad(0, ctx:px(10), 0, ctx:px(10)):radius(ctx:radius("sm"))
		:bg(ctx:color("bg")):border(ctx:px(1), ctx:color("border")):text(ctx:type("sm")):fg(ctx:color("text"))
	if props.width ~= nil then
		fieldStyle:w(props.width)
	else
		fieldStyle:wrel(1.0)
	end
	local input = div()
		:style(fieldStyle)
		:input({ name = props.name, value = props.value, oninput = props.oninput, onsubmit = props.onsubmit })
	input:children(text(shown):style(ctx:s():wrel(1.0):text(ctx:type("sm")):fg(colour):ellipsis()))
	return input
end

return { view = field.view }
