-- A row in a list: a height, the row's children, a hover fill and the message a click sends. The
-- active fill is for the entry the app is already showing, so a navigation row can say where the
-- person is without a second component.
local wonderland = require("wonderland")

local div, sty = wonderland.div, wonderland.sty

local listRow = {}

---@class beat.ui.ListRowProps
---@field height number
---@field children wonderland.Element[]? # Laid out left to right
---@field onClick any? # The message a click sends
---@field width number? # Default fills the room its parent gives it
---@field gap number? # Space between the children; default none
---@field padding number? # Horizontal padding; default px(10)
---@field justify "start"|"center"|"space-between"? # Default "start"
---@field active boolean? # Draws the current-destination fill
---@field radius string? # A radius name; default "sm"

---@param ctx beat.ui.Context
---@param props beat.ui.ListRowProps
---@return wonderland.Element
function listRow.view(ctx, props)
	local padding = props.padding or ctx:px(10)

	local function style(fill)
		local value = sty()
			:row():h(props.height):pad(0, padding, 0, padding):radius(ctx:radius(props.radius or "sm")):align("center")
		if props.width ~= nil then value:w(props.width) else value:wrel(1.0) end
		if props.gap ~= nil then value:gap(props.gap) end
		if props.justify ~= nil then value:justify(props.justify) end
		if fill ~= nil then value:bg(fill) end
		return value
	end

	local row = div()
		:style(style(props.active and ctx:color("elevated") or nil))
		:hover(style(ctx:color("hover")))
	if props.onClick ~= nil then row:onClick(props.onClick) end
	return row:children(props.children or {})
end

return { view = listRow.view }
