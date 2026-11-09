-- A check box that records a switch: a square box with the icon face's check drawn in it when it
-- is on, and a larger invisible hit area around it. The click sends the message the caller gives
-- it; the component does not keep the state itself, so the row that shows a switch and the value
-- the app saved can never disagree.
local wonderland = require("wonderland")
local icon = require("beat-ui.icon")

local div, sty = wonderland.div, wonderland.sty

local checkbox = {}

---@class beat.ui.CheckboxProps
---@field checked boolean # Whether the box is drawn on
---@field onClick any # The message a click sends
---@field size number? # The box itself; default px(20)
---@field target number? # The clickable square around it; default px(32)

---@param ctx beat.ui.Context
---@param props beat.ui.CheckboxProps
---@return wonderland.Element
function checkbox.view(ctx, props)
	local size = props.size or ctx:px(20)
	local target = props.target or ctx:px(32)
	local box = sty():size(size, size):radius(ctx:radius("sm")):align("center"):justify("center")
	local content = {}
	if props.checked then
		box:bg(ctx:color("accent")):border(ctx:px(1), ctx:color("accent"))
		content[1] = icon.view(ctx, {
			name = "check",
			size = math.max(ctx:px(14), math.floor(size * 0.7 + 0.5)),
			colour = ctx.accentInk
		})
	else
		box:border(ctx:px(1.5), ctx:color("muted"))
	end

	return div()
		:style(sty():size(target, target):align("center"):justify("center"))
		:onClick(props.onClick)
		:children({ div():style(box):children(content) })
end

return { view = checkbox.view }
