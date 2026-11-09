-- A panel with a border: the shape Settings and Plugins put every group of controls in. A title is
-- drawn at the top, optionally with an action at its right edge; the rest is the caller's. The
-- height is the caller's when it needs one, and otherwise the content plus the padding and gaps.
local wonderland = require("wonderland")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local card = {}

---@class beat.ui.CardProps
---@field title string? # The heading at the top; omitted for a plain panel
---@field action wonderland.Element? # A control at the title row's right edge
---@field children wonderland.Element[]? # The card's body, after the title row
---@field width number? # Default fills the room its parent gives it
---@field height number? # The card's height; when absent it fills the height its parent gives it
---@field padding number? # Default px(18)
---@field gap number? # Default px(12)
---@field radius string? # A radius name; default "md"

---@param ctx beat.ui.Context
---@param props beat.ui.CardProps
---@return wonderland.Element
function card.view(ctx, props)
	local padding = props.padding or ctx:px(18)
	local gap = props.gap or ctx:px(12)
	local style = sty()
		:column():pad(padding):gap(gap):radius(ctx:radius(props.radius or "md")):bg(ctx:color("surface"))
		:border(ctx:px(1), ctx:color("border"))
	if props.width ~= nil then
		style:w(props.width)
	else
		style:wrel(1.0)
	end
	if props.height ~= nil then style:h(props.height) end

	local children = {}
	if props.title ~= nil or props.action ~= nil then
		local head = {}
		if props.title ~= nil then
			head[#head + 1] = text(props.title)
				:style(ctx:s():wrel(1.0):text(ctx:type("lg")):weight("bold"):fg(ctx:color("text")):ellipsis())
		end
		if props.action ~= nil then head[#head + 1] = props.action end
		children[#children + 1] = div()
			:style(
				sty()
					:row():wrel(1.0):h(props.action ~= nil and ctx:px(32) or ctx:px(24))
					:align("center"):justify("space-between")
			)
			:children(head)
	end
	for _, child in ipairs(props.children or {}) do children[#children + 1] = child end

	return div():style(style):children(children)
end

return { view = card.view }
