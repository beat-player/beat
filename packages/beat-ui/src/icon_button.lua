-- A control that is only a glyph or a small drawing: the round hit area every icon in the app sits
-- in, and what fills it. `content` lets a caller draw its own mark (the task button's badge, the
-- library's view toggle) while keeping the same hit area and hover.
local wonderland = require("wonderland")
local icon = require("beat-ui.icon")
local cache = require("beat-ui.cache")
local ripple = require("beat-ui.ripple")

local div, sty = wonderland.div, wonderland.sty

local iconButton = {}

---@class beat.ui.IconButtonProps
---@field name string? # The icon face's name; required when `content` is absent
---@field content wonderland.Element? # Drawn instead of a glyph
---@field size number # The hit area, and the box the glyph sits in
---@field onClick any # The message a click sends
---@field active boolean? # Draws the glyph in the text colour rather than muted
---@field key string? # Keeps the press mark on this button across frames; default its place in the frame

---@class beat.ui.IconButtonStyles
---@field base wonderland.StyleBuilder
---@field hover wonderland.StyleBuilder

--- The hit area is a size and the theme's full radius, and the hover only fills it: one record per
--- size is every icon button on the screen.
---@param ctx beat.ui.Context
---@param size number
---@return beat.ui.IconButtonStyles
local function iconButtonStyles(ctx, size)
	local radius = ctx:radius("full")
	return {
		base = sty():size(size, size):radius(radius):align("center"):justify("center"),
		hover = sty():size(size, size):radius(radius):bg(ctx:color("hover")):align("center"):justify("center")
	}
end

---@param ctx beat.ui.Context
---@param props beat.ui.IconButtonProps
---@return wonderland.Element
function iconButton.view(ctx, props)
	local colour = props.active ? (ctx:color("text")) : (ctx:color("muted"))
	local content = props.content
	if content == nil then
		local name = assert(props.name, "an icon button needs a name or content")
		local glyphSize = math.max(18, math.floor(props.size * 0.8 + 0.5))
		content = icon.view(ctx, { name = name, size = glyphSize, colour = colour })
	end

	local styles = cache.of(ctx, iconButtonStyles, "iconButton", props.size) --[[@as beat.ui.IconButtonStyles]]

	-- The mark is drawn in the colour of what is in the button: a glyph that is text, a picture that
	-- is not takes the colour the button around it uses.
	local element = div():style(styles.base):hover(styles.hover):onClick(props.onClick):children(content)
	ripple.attach(element, props.key, colour)

	return element
end

return { view = iconButton.view }
