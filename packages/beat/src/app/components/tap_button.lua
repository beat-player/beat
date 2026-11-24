-- A control whose hit area can be larger than its mark: the phone's transport and tool buttons
-- keep their glyph but get a thumb-sized box around it, and the box is transparent.
local ui = require("beat-ui")

local tapButton = {}

---@class beat.components.TapButtonProps
---@field name string # The icon face's name
---@field size number # The mark's size: the glyph is drawn at a share of it
---@field hit number # The box that answers a thumb, around the mark
---@field onClick any # The message a click sends
---@field active boolean? # Draws the glyph in the text colour rather than muted

---@param ctx beat.ui.Context
---@param props beat.components.TapButtonProps
---@return wonderland.Element
function tapButton.view(ctx, props)
	local colour = props.active ? (ctx:color("text")) : (ctx:color("muted"))
	local glyphSize = math.max(18, math.floor(props.size * 0.8 + 0.5))
	return ui.iconButton(ctx, {
		size = props.hit,
		onClick = props.onClick,
		content = ui.icon(ctx, { name = props.name, size = glyphSize, colour = colour })
	})
end

return tapButton
