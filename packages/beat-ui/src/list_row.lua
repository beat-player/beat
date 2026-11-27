-- A row in a list: a height, the row's children, a hover fill and the message a click sends. The
-- active fill is for the entry the app is already showing, so a navigation row can say where the
-- person is without a second component.
local wonderland = require("wonderland")
local cache = require("beat-ui.cache")
local ripple = require("beat-ui.ripple")

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
---@field key string? # Keeps the press mark on this row across frames; default its place in the frame

---@class beat.ui.ListRowStyles
---@field base wonderland.StyleBuilder
---@field hover wonderland.StyleBuilder

---@param ctx beat.ui.Context
---@param height number
---@param padding number
---@param radiusName string
---@param active boolean
---@param width number|string # The width, or "rel" for a share of the parent
---@param gap number|string # The gap, or "none"
---@param justify string # The justification, or "-"
---@return beat.ui.ListRowStyles
local function listRowStyles(ctx, height, padding, radiusName, active, width, gap, justify)
	local radius = ctx:radius(radiusName)
	local base = sty():row():h(height):pad(0, padding, 0, padding):radius(radius):align("center")
	local hover = sty():row():h(height):pad(0, padding, 0, padding):radius(radius):align("center")
	if type(width) == "number" then
		base:w(width)
		hover:w(width)
	else
		base:wrel(1.0)
		hover:wrel(1.0)
	end
	if type(gap) == "number" then
		base:gap(gap)
		hover:gap(gap)
	end
	if justify ~= "-" then
		base:justify(justify --[[@as "start"|"center"|"end"|"space-between"|"space-around"]] )
		hover:justify(justify --[[@as "start"|"center"|"end"|"space-between"|"space-around"]] )
	end
	if active then base:bg(ctx:color("elevated")) end
	hover:bg(ctx:color("hover"))
	return { base = base, hover = hover }
end

---@param ctx beat.ui.Context
---@param props beat.ui.ListRowProps
---@return wonderland.Element
function listRow.view(ctx, props)
	local padding = props.padding or ctx:px(10)

	-- Every list on the screen -- the sidebar, a menu, a picker -- draws rows of one or two heights,
	-- so the base and the hover of each combination are made once and handed to every frame.
	local styles = cache.of(
		ctx,
		listRowStyles,
		"listRow",
		props.height,
		padding,
		props.radius or "sm",
		props.active == true,
		props.width or "rel",
		props.gap or "none",
		props.justify or "-"
	) --[[@as beat.ui.ListRowStyles]]

	local row = div():style(styles.base):hover(styles.hover)
	if props.onClick ~= nil then
		row:onClick(props.onClick)
		-- A row that answers a press is a row that shows one: the mark of its own ink, inside the
		-- rounded box it is drawn in.
		ripple.attach(row, props.key, ctx:color("text"))
	end
	return row:children(props.children or {})
end

return { view = listRow.view }
