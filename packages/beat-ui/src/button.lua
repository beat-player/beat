-- A word the app offers as an action: one filled, outlined or plain box, an optional glyph before
-- the text, and the message a click sends.
--
-- The variant decides how the button sits on the surface under it. `primary` is the accent-filled
-- action a screen offers once; `secondary` keeps the raised fill and adds a hairline border, so it
-- reads on a page, a card and the elevated panel of a dialog alike; `quiet` has no fill until the
-- pointer is over it and is for a third, less important action.
local wonderland = require("wonderland")
local icon = require("beat-ui.icon")
local measure = require("beat-ui.measure")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local button = {}

---@class beat.ui.ButtonProps
---@field label string # What the button says
---@field onClick any # The message a click sends
---@field variant "primary"|"secondary"|"quiet"? # Default "secondary"
---@field width number? # A fixed width; default the label's own width
---@field height number? # Default px(36)
---@field icon string? # An icon name drawn before the label

---@param ctx beat.ui.Context
---@param props beat.ui.ButtonProps
---@return wonderland.Element
function button.view(ctx, props)
	local height = props.height or ctx:px(36)
	local variant = props.variant or "secondary"
	---@type string?
	local colour
	---@type string?
	local background
	---@type string?
	local hover
	---@type string?
	local border
	---@type string?
	local hoverBorder
	if variant == "primary" then
		colour = ctx.accentInk
		background = ctx:color("accent")
		hover = ctx:color("accent", 0.86)
	elseif variant == "quiet" then
		colour = ctx:color("muted")
		hover = ctx:color("hover")
	else
		-- A step lighter than every panel a button sits on -- the page, a card's `surface`, a
		-- dialog's `elevated` -- so a secondary button is a button wherever it is drawn.
		colour = ctx:color("text")
		background = ctx:color("hover")
		hover = ctx:color("active")
		border = ctx:color("border")
		hoverBorder = ctx:color("border")
	end
	local gap = ctx:px(6)
	local labelWidth = measure.estimate(props.label, ctx:type("sm"), 0.48)
	local autoWidth = labelWidth + ctx:px(16) * 2 + (props.icon ~= nil and (ctx:px(16) + gap) or 0)
	local width = props.width or autoWidth

	local function base(fill, stroke)
		local style = sty()
			:h(height):pad(0, ctx:px(16), 0, ctx:px(16)):row():align("center"):justify("center"):gap(gap)
			:radius(ctx:radius("sm"))
		if fill ~= nil then style:bg(fill) end
		if stroke ~= nil then style:border(ctx:px(1), stroke) end
		style:w(width)
		return style
	end

	local children = {}
	if props.icon ~= nil then
		children[#children + 1] = icon.view(ctx, { name = props.icon, size = ctx:px(16), colour = colour })
	end
	children[#children + 1] = text(props.label):style(ctx:s():text(ctx:type("sm")):weight("semibold"):fg(colour))

	return div():style(base(background, border)):hover(base(hover, hoverBorder)):onClick(props.onClick):children(children)
end

return { view = button.view }
