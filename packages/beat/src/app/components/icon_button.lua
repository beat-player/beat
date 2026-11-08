-- A control that is only a glyph: the round hit area every icon in the app sits in, and the
-- named icon that fills it.
local wonderland = require("wonderland")
local icon = require("beat.app.components.icon")

local div, sty = wonderland.div, wonderland.sty

local iconButton = {}

---@class beat.components.IconButtonProps
---@field name string # The icon face's name
---@field size number # The hit area, and the box the glyph sits in
---@field onClick any # The message a click sends
---@field active boolean? # Draws the glyph in the text colour rather than muted

---@class beat.components.IconSurfaceProps
---@field size number # The hit area
---@field onClick any # The message a click sends
---@field content wonderland.Element # What sits in the middle of the hit area

--- The hit area on its own, for a control that draws its own glyph rather than taking one from
--- the icon face.
---@param app beat.App
---@param props beat.components.IconSurfaceProps
---@return wonderland.Element
function iconButton.surface(app, props)
	local theme = app.services.appearance.theme
	local size = props.size

	return div()
		:style(sty():size(size, size):radius(theme:radius("full")):align("center"):justify("center"))
		:hover(sty():size(size, size):radius(theme:radius("full")):bg(theme:color("hover")):align("center"):justify("center"))
		:onClick(props.onClick):children({ props.content })
end

---@param app beat.App
---@param props beat.components.IconButtonProps
---@return wonderland.Element
function iconButton.view(app, props)
	local theme = app.services.appearance.theme
	local colour = props.active ? (theme:color("text")) : (theme:color("muted"))

	local glyphSize = math.max(18, math.floor(props.size * 0.8 + 0.5))
	return iconButton.surface(
		app,
		{
			size = props.size,
			onClick = props.onClick,
			content = icon.view(app, { name = props.name, size = glyphSize, colour = colour })
		}
	)
end

return iconButton
