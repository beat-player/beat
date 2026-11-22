-- A named text field for a dialog. The text is a child of the input element rather than a sibling
-- drawn over it: the caret and a selection are placed from the run inside the field, so text
-- outside it leaves them at the field's origin with the wrong line height.
local wonderland = require("wonderland")
local cache = require("beat-ui.cache")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local field = {}

---@class beat.ui.FieldProps
---@field name string # The input's focus id
---@field value string
---@field placeholder string # Shown until there is a value, or while focused and empty
---@field oninput fun(value: string): any
---@field onsubmit fun(): any
---@field width number? # Default fills the room its parent gives it

---@class beat.ui.FieldStyles
---@field well wonderland.StyleBuilder
---@field text wonderland.StyleBuilder

--- An inset well: darker than whatever it sits on and edged with a hairline, so the box is the
--- same on a page, on a card (whose fill is `surface`) and on a dialog (whose fill is `elevated`).
---@param ctx beat.ui.Context
---@param width number|string # The width, or "rel" for a share of the parent
---@param colour string # What the text is drawn in, which is the field's own state
---@return beat.ui.FieldStyles
local function fieldStyles(ctx, width, colour)
	local well = sty()
		:h(ctx:px(34)):row():align("center"):pad(0, ctx:px(10), 0, ctx:px(10)):radius(ctx:radius("sm")):bg(ctx:color("bg"))
		:border(ctx:px(1), ctx:color("border")):text(ctx:type("sm")):fg(ctx:color("text"))
	if type(width) == "number" then
		well:w(width)
	else
		well:wrel(1.0)
	end
	return { well = well, text = ctx:s():wrel(1.0):text(ctx:type("sm")):fg(colour):ellipsis() }
end

---@param ctx beat.ui.Context
---@param props beat.ui.FieldProps
---@return wonderland.Element
function field.view(ctx, props)
	local focused = ctx:focused(props.name)
	local shown = props.value ~= "" and props.value or (focused and " " or props.placeholder)
	local colour = props.value ~= "" ? (ctx:color("text")) : focused and (ctx:color("text")) or (ctx:color("faint"))

	local styles = cache.of(ctx, fieldStyles, "field", props.width or "rel", colour) --[[@as beat.ui.FieldStyles]]

	local input = div():style(styles.well):input({
		name = props.name,
		value = props.value,
		oninput = props.oninput,
		onsubmit = props.onsubmit
	})
	input:children(text(shown):style(styles.text))
	return input
end

return { view = field.view }
