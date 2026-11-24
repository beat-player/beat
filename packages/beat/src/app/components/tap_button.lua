-- A control whose hit area can be larger than its mark: the phone's transport and tool buttons
-- keep their glyph but get a thumb-sized box around it, and the box is transparent.
local ui = require("beat-ui")

local tapButton = {}

-- What the icon button under the mark is built from, written again each call: the button reads it
-- and keeps nothing, and the phone's transport is built on every frame it is on.
---@type beat.ui.IconButtonProps
local buttonProps = { size = 0, onClick = nil }

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
	buttonProps.size, buttonProps.onClick = props.hit, props.onClick
	buttonProps.content = ui.icon(ctx, { name = props.name, size = glyphSize, colour = colour })
	return ui.iconButton(ctx, buttonProps)
end

return tapButton
