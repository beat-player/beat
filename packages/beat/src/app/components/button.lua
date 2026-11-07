-- A word the app offers as an action: one raised or filled box, an optional glyph before it, and
-- the message its click sends.
local wonderland = require("wonderland")
local icon = require("beat.app.components.icon")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local button = {}

---@class beat.components.ButtonProps
---@field label string # What the button says
---@field onClick any # The message a click sends
---@field primary boolean? # Accent-filled rather than raised; default false
---@field width number? # A fixed width; default the label's own width
---@field height number? # Default theme:px(36)
---@field icon string? # An icon name drawn before the label

---@param app beat.App
---@param props beat.components.ButtonProps
---@return wonderland.Element
function button.view(app, props)
	local theme = app.services.appearance.theme
	local height = props.height or theme:px(36)
	local colour = props.primary and theme.accentInk or theme:color("text")
	local background = props.primary and theme:color("accent") or theme:color("elevated")
	local hover = props.primary and theme:color("accent", 0.86) or theme:color("hover")
	local gap = theme:px(6)

	local function base(fill)
		local style = sty()
		:h(height)
		:pad(0, theme:px(16), 0, theme:px(16))
		:row()
		:align("center")
		:justify("center")
		:gap(gap)
		:radius(theme:radius("sm"))
		:bg(fill)
		if props.width ~= nil then style:w(props.width) end
		return style
	end

	local children = {}
	if props.icon ~= nil then
		children[#children + 1] = icon.view(app, { name = props.icon, size = theme:px(16), colour = colour })
	end
	children[#children + 1] = text(props.label):style(theme:s():text(theme:type("sm"))
	:weight("semibold"):fg(colour))

	return div()
	:style(base(background))
	:hover(base(hover))
	:onClick(props.onClick)
	:children(children)
end

return button
