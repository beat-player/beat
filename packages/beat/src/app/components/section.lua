-- A heading on a page, with the "See all" link that opens the full list where there is one.
local wonderland = require("wonderland")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local section = {}

---@class beat.components.SectionProps
---@field title string
---@field action any? # The message "See all" sends; omitted, the heading stands alone

---@param app beat.App
---@param props beat.components.SectionProps
---@return wonderland.Element
function section.view(app, props)
	local theme = app.services.appearance.theme
	local children = {
		text(props.title):style(theme:s():text(theme:type("lg")):weight("bold"):fg(theme:color("text"))),
	}

	if props.action ~= nil then
		children[#children + 1] = text("See all"):style(theme:s():text(theme:type("sm")):weight("semibold")
		:fg(theme:color("muted"))):onClick(props.action)
	end

	return div():style(sty():row():wrel(1.0):h(theme:px(24)):align("end"):justify("space-between"))
	:children(children)
end

return section
