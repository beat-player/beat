-- The screen a collection shows when it has nothing in it: a drawn record (or an icon), a title,
-- an explanation, and the one action that fills it.
local wonderland = require("wonderland")
local button = require("beat.app.components.button")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local emptyState = {}

---@class beat.components.EmptyStateProps
---@field title string
---@field copy string? # The line under the title, wrapped to the window
---@field actionLabel string? # The button's label; omitted with `action`
---@field action any? # The message the button sends
---@field icon string? # An emoji or glyph instead of the drawn record

---@param app beat.App
---@param props beat.components.EmptyStateProps
---@return wonderland.Element
function emptyState.view(app, props)
	local theme = app.services.appearance.theme
	local copy, actionLabel, action = props.copy, props.actionLabel, props.action

	local children = {}
	if props.icon ~= nil then
		children[#children + 1] = text(props.icon):style(theme:s():text(theme:px(40))
		:fg(theme:color("text")))
	else
		children[#children + 1] = div():style(sty():size(120, 120)):canvas(function(canvas)
			canvas:circle(canvas.width / 2, canvas.height / 2, canvas.width * 0.38,
			theme:color("elevated"))
			canvas:circle(canvas.width / 2, canvas.height / 2, canvas.width * 0.09,
			theme:color("accent", 0.55))
			for at = 0, 11 do
				local angle = at / 12 * math.pi * 2
				canvas:line(canvas.width / 2 + math.cos(angle) * canvas.width * 0.14,
				canvas.height / 2 + math.sin(angle) * canvas.height * 0.14,
				canvas.width / 2 + math.cos(angle) * canvas.width * 0.25,
				canvas.height / 2 + math.sin(angle) * canvas.height * 0.25,
				theme:px(2), theme:color("text", 0.08))
			end
		end)
	end
	children[#children + 1] = text(props.title):style(theme:s():text(theme:type("xl")):weight("bold")
	:fg(theme:color("text")))
	if copy ~= nil then
		local copyWidth = theme:px(420)
		if app.window ~= nil then
			copyWidth = math.min(copyWidth, app.window.width - theme:space(64))
		end
		children[#children + 1] = text(copy):style(theme:s():w(copyWidth):text(theme:type("sm"))
		:fg(theme:color("muted")):align("center"))
	end

	if actionLabel ~= nil and action ~= nil then
		children[#children + 1] = button.view(app, {
			label = actionLabel,
			onClick = action,
			primary = true,
			width = theme:px(160),
		})
	end

	return div():style(sty():fill():column():align("center"):justify("center"):gap(theme:px(14)))
	:children(children)
end

return emptyState
