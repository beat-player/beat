-- Back on the first page of a phone leaves the app, and a back gesture is easy to make by accident:
-- the app asks first. Back again, or a tap beside the panel, keeps it open.
local wonderland = require("wonderland")
local ui = require("beat-ui")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.ConfirmLeaveOverlay: beat.OverlaySurface
local confirmLeave = {}

function confirmLeave.new()
	return {}
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.OverlayState>
---@param message beat.Message
function confirmLeave.update(app, overlay, message)
	if message.type == "confirmLeave" then
		app:close(overlay)
		app:leave()
		return true
	elseif message.type == "cancelLeave" then
		app:close(overlay)
		return true
	end
	return false
end

---@param app beat.App
---@param window wonderland.RenderWindow
function confirmLeave.view(app, _, window)
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local panelWidth = ctx:panelWidth(340)
	local pad = theme:px(18)
	local buttonHeight = theme:px(40)

	local panel = div()
		:style(
			sty()
				:w(panelWidth):h(pad * 2 + theme:px(36) + theme:px(12) + buttonHeight):column():pad(pad):gap(theme:px(12))
				:radius(theme:radius("lg")):bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
				:shadow(0, theme:px(16), theme:px(42), "#00000080")
		):onClick({ type = "keep" })
		:children(
			{
				text("Leave beat?")
					:style(theme:s():wrel(1.0):h(theme:px(36)):text(theme:type("lg")):weight("bold"):fg(theme:color("text"))),
				div()
					:style(sty():row():wrel(1.0):h(buttonHeight):gap(theme:px(8)):align("center"):justify("end"))
					:children(
						{
							ui.button(ctx, { label = "Stay", onClick = { type = "cancelLeave" }, height = buttonHeight, width = theme:px(90) }),
							ui.button(
								ctx,
								{
									label = "Leave",
									variant = "primary",
									onClick = { type = "confirmLeave" },
									height = buttonHeight,
									width = theme:px(90)
								}
							)
						}
					)
			}
		)

	return div()
		:style(sty():fill():offset(0, 0):z(124):column():align("center"):justify("center"):bg(theme:color("overlay")))
		:onClick({ type = "cancelLeave" }):children({ panel })
end

return confirmLeave
