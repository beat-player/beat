-- A panel with a border: the shape Settings and Plugins put every group of controls in. A title is
-- drawn at the top, optionally with an action at its right edge; the rest is the caller's. The
-- height is the caller's when it needs one, and otherwise the content plus the padding and gaps.
local wonderland = require("wonderland")
local cache = require("beat-ui.cache")

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

---@class beat.ui.CardStyles
---@field panel wonderland.StyleBuilder
---@field title wonderland.StyleBuilder
---@field head wonderland.StyleBuilder

--- A page of cards is a handful of sizes: the panel's, the title row's and the heading's, all of
--- them the same in every frame.
---@param ctx beat.ui.Context
---@param padding number
---@param gap number
---@param radiusName string
---@param width number|string # The width, or "rel"
---@param height number|string # The height, or "none"
---@param hasAction boolean
---@return beat.ui.CardStyles
local function cardStyles(ctx, padding, gap, radiusName, width, height, hasAction)
	local panel = sty()
		:column():pad(padding):gap(gap):radius(ctx:radius(radiusName)):bg(ctx:color("surface"))
		:border(ctx:px(1), ctx:color("border"))
	if type(width) == "number" then
		panel:w(width)
	else
		panel:wrel(1.0)
	end
	if type(height) == "number" then panel:h(height) end
	return {
		panel = panel,
		title = ctx:s():wrel(1.0):text(ctx:type("lg")):weight("bold"):fg(ctx:color("text")):ellipsis(),
		head = sty():row():wrel(1.0):h(hasAction and ctx:px(32) or ctx:px(24)):align("center"):justify("space-between")
	}
end

---@param ctx beat.ui.Context
---@param props beat.ui.CardProps
---@return wonderland.Element
function card.view(ctx, props)
	local padding = props.padding or ctx:px(18)
	local gap = props.gap or ctx:px(12)

	local styles = cache.of(
		ctx,
		cardStyles,
		"card",
		padding,
		gap,
		props.radius or "md",
		props.width or "rel",
		props.height or "none",
		props.action ~= nil
	) --[[@as beat.ui.CardStyles]]

	local children = {}
	if props.title ~= nil or props.action ~= nil then
		local head = {}
		if props.title ~= nil then head[#head + 1] = text(props.title):style(styles.title) end
		if props.action ~= nil then head[#head + 1] = props.action end
		children[#children + 1] = div():style(styles.head):children(head)
	end
	for _, child in ipairs(props.children or {}) do children[#children + 1] = child end

	return div():style(styles.panel):children(children)
end

return { view = card.view }
