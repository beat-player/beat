-- The screen a collection shows when it has nothing in it: a drawn record (or an icon), a title,
-- an explanation, and the one action that fills it.
local wonderland = require("wonderland")
local button = require("beat-ui.button")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local emptyState = {}

---@class beat.ui.EmptyStateProps
---@field title string
---@field copy string? # The line under the title, wrapped to the window
---@field actionLabel string? # The button's label; omitted with `action`
---@field action any? # The message the button sends
---@field icon string? # An emoji or glyph instead of the drawn record

---@param ctx beat.ui.Context
---@param props beat.ui.EmptyStateProps
---@return wonderland.Element
function emptyState.view(ctx, props)
	local copy, actionLabel, action = props.copy, props.actionLabel, props.action

	local children = {}
	if props.icon ~= nil then
		children[#children + 1] = text(props.icon):style(ctx:s():text(ctx:px(40)):fg(ctx:color("text")))
	else
		children[#children + 1] = div():style(sty():size(120, 120)):canvas(function(canvas)
			canvas:circle(canvas.width / 2, canvas.height / 2, canvas.width * 0.38, ctx:color("elevated"))
			canvas:circle(canvas.width / 2, canvas.height / 2, canvas.width * 0.09, ctx:color("accent", 0.55))
			for at = 0, 11 do
				local angle = at / 12 * math.pi * 2
				canvas:line(
					canvas.width / 2 + math.cos(angle) * canvas.width * 0.14,
					canvas.height / 2 + math.sin(angle) * canvas.height * 0.14,
					canvas.width / 2 + math.cos(angle) * canvas.width * 0.25,
					canvas.height / 2 + math.sin(angle) * canvas.height * 0.25,
					ctx:px(2),
					ctx:color("text", 0.08)
				)
			end
		end)
	end
	children[#children + 1] = text(props.title)
		:style(ctx:s():text(ctx:type("xl")):weight("bold"):fg(ctx:color("text")))
	if copy ~= nil then
		local copyWidth = math.min(ctx:px(420), ctx.width - ctx:space(64))
		children[#children + 1] = text(copy)
			:style(ctx:s():w(copyWidth):text(ctx:type("sm")):fg(ctx:color("muted")):align("center"))
	end

	if actionLabel ~= nil and action ~= nil then
		children[#children + 1] = button.view(
			ctx,
			{ label = actionLabel, onClick = action, variant = "primary", width = ctx:px(160) }
		)
	end

	return div():style(sty():fill():column():align("center"):justify("center"):gap(ctx:px(14))):children(children)
end

return { view = emptyState.view }
