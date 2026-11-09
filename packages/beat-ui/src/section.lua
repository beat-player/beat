-- A heading on a page, with the "See all" link that opens the full list where there is one.
local wonderland = require("wonderland")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local section = {}

---@class beat.ui.SectionProps
---@field title string
---@field action any? # The message "See all" sends; omitted, the heading stands alone

---@param ctx beat.ui.Context
---@param props beat.ui.SectionProps
---@return wonderland.Element
function section.view(ctx, props)
	local children = { text(props.title):style(ctx:s():text(ctx:type("lg")):weight("bold"):fg(ctx:color("text"))) }

	if props.action ~= nil then
		children[#children + 1] = text("See all")
			:style(ctx:s():text(ctx:type("sm")):weight("semibold"):fg(ctx:color("muted"))):onClick(props.action)
	end

	return div():style(sty():row():wrel(1.0):h(ctx:px(24)):align("end"):justify("space-between")):children(children)
end

return { view = section.view }
