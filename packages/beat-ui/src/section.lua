-- A heading on a page, with the "See all" link that opens the full list where there is one.
local wonderland = require("wonderland")
local cache = require("beat-ui.cache")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local section = {}

---@class beat.ui.SectionProps
---@field title string
---@field action any? # The message "See all" sends; omitted, the heading stands alone

---@class beat.ui.SectionStyles
---@field title wonderland.StyleBuilder
---@field action wonderland.StyleBuilder
---@field row wonderland.StyleBuilder

--- A page's headings all say the same thing in the theme's two colours.
---@param ctx beat.ui.Context
---@param hasAction boolean
---@return beat.ui.SectionStyles
local function sectionStyles(ctx, hasAction)
	return {
		title = ctx:s():text(ctx:type("lg")):weight("bold"):fg(ctx:color("text")),
		action = ctx:s():text(ctx:type("sm")):weight("semibold"):fg(ctx:color("muted")),
		row = sty():row():wrel(1.0):h(ctx:px(24)):align("end"):justify("space-between")
	}
end

---@param ctx beat.ui.Context
---@param props beat.ui.SectionProps
---@return wonderland.Element
function section.view(ctx, props)
	local styles = cache.of(ctx, sectionStyles, "section", props.action ~= nil) --[[@as beat.ui.SectionStyles]]

	local element = div():style(styles.row):children(text(props.title):style(styles.title))
	if props.action ~= nil then
		element:children(text("See all"):style(styles.action):onClick(props.action))
	end
	return element
end

return { view = section.view }
