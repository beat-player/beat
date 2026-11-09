-- A control that is only a glyph or a small drawing: the round hit area every icon in the app sits
-- in, and what fills it. `content` lets a caller draw its own mark (the task button's badge, the
-- library's view toggle) while keeping the same hit area and hover.
local wonderland = require("wonderland")
local icon = require("beat-ui.icon")

local div, sty = wonderland.div, wonderland.sty

local iconButton = {}

---@class beat.ui.IconButtonProps
---@field name string? # The icon face's name; required when `content` is absent
---@field content wonderland.Element? # Drawn instead of a glyph
---@field size number # The hit area, and the box the glyph sits in
---@field onClick any # The message a click sends
---@field active boolean? # Draws the glyph in the text colour rather than muted

---@param ctx beat.ui.Context
---@param props beat.ui.IconButtonProps
---@return wonderland.Element
function iconButton.view(ctx, props)
	local colour = props.active ? (ctx:color("text")) : (ctx:color("muted"))
	local content = props.content
	if content == nil then
		local name = assert(props.name, "an icon button needs a name or content")
		local glyphSize = math.max(18, math.floor(props.size * 0.8 + 0.5))
		content = icon.view(ctx, { name = name, size = glyphSize, colour = colour })
	end

	return div()
		:style(sty():size(props.size, props.size):radius(ctx:radius("full")):align("center"):justify("center"))
		:hover(
			sty()
				:size(props.size, props.size):radius(ctx:radius("full")):bg(ctx:color("hover")):align("center"):justify("center")
		)
		:onClick(props.onClick):children({ content })
end

return { view = iconButton.view }
