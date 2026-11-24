-- A word the app offers as an action: one filled, outlined or plain box, an optional glyph before
-- the text, and the message a click sends.
--
-- The variant decides how the button sits on the surface under it. `primary` is the accent-filled
-- action a screen offers once; `secondary` keeps the raised fill and adds a hairline border, so it
-- reads on a page, a card and the elevated panel of a dialog alike; `quiet` has no fill until the
-- pointer is over it and is for a third, less important action.
local wonderland = require("wonderland")
local icon = require("beat-ui.icon")
local cache = require("beat-ui.cache")
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

---@class beat.ui.ButtonStyles
---@field base wonderland.StyleBuilder
---@field hover wonderland.StyleBuilder
---@field label wonderland.StyleBuilder
---@field colour string # What the label is drawn in, which the icon before it takes too

--- The variant, the geometry and whether there is a glyph are the whole of what a button's styles
--- say, so a button that says the same thing in every frame is one record of builders handed over
--- again.
---@param ctx beat.ui.Context
---@param variant "primary"|"secondary"|"quiet"
---@param height number
---@param width number
---@param gap number
---@param hasIcon boolean
---@return beat.ui.ButtonStyles
local function buttonStyles(ctx, variant, height, width, gap, hasIcon)
	---@type string
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

	local pad = ctx:px(16)
	local stroke = ctx:px(1)
	local radius = ctx:radius("sm")
	local base = sty():h(height):pad(0, pad, 0, pad):row():align("center"):justify("center"):gap(gap):radius(radius)
	local hoverStyle = sty():h(height):pad(0, pad, 0, pad):row():align("center"):justify("center"):gap(gap):radius(radius)
	if background ~= nil then base:bg(background) end
	if border ~= nil then base:border(stroke, border) end
	if hover ~= nil then hoverStyle:bg(hover) end
	if hoverBorder ~= nil then hoverStyle:border(stroke, hoverBorder) end
	base:w(width)
	hoverStyle:w(width)

	return {
		base = base,
		hover = hoverStyle,
		label = ctx:s():text(ctx:type("sm")):weight("semibold"):fg(colour),
		colour = colour
	}
end

---@param ctx beat.ui.Context
---@param props beat.ui.ButtonProps
---@return wonderland.Element
function button.view(ctx, props)
	local height = props.height or ctx:px(36)
	local variant = props.variant
	if variant ~= "primary" and variant ~= "quiet" then variant = "secondary" end
	local gap = ctx:px(6)
	local labelWidth = measure.estimate(props.label, ctx:type("sm"), 0.48)
	local autoWidth = labelWidth + ctx:px(16) * 2 + (props.icon ~= nil and (ctx:px(16) + gap) or 0)
	local width = props.width or autoWidth

	local styles = cache.of(ctx, buttonStyles, "button", variant, height, width, gap, props.icon ~= nil) --[[@as beat.ui.ButtonStyles]]

	-- The icon and the label are handed over one at a time: a button is built on every frame of
	-- the screens it is on, and a table it is only a list of is a table that frame does not need.
	local element = div():style(styles.base):hover(styles.hover):onClick(props.onClick)
	if props.icon ~= nil then
		element:children(icon.view(ctx, { name = props.icon, size = ctx:px(16), colour = styles.colour }))
	end
	return element:children(text(props.label):style(styles.label))
end

return { view = button.view }
