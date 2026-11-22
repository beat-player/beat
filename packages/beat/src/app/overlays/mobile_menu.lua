-- The phone's own menu: the two places the top bar no longer has room for in its corner. It opens
-- above the tabs and the player bar, where the hand that pressed the last tab already is.
local wonderland = require("wonderland")
local metrics = require("beat.app.components.helpers.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.MobileMenuOverlay: beat.OverlaySurface
local mobileMenu = { light = true }

function mobileMenu.new()
	return {}
end

---@param app beat.App
---@param overlay beat.OverlayInstance
---@param message beat.Message
function mobileMenu.update(app, overlay, message)
	-- The More tab closes what it opened rather than opening a second one.
	if message.type == "open" and message.overlay == "mobile_menu" then
		app:close(overlay)
		return true
	end
	return false
end

---@param app beat.App
---@param ctx beat.ui.Context
---@param width number
---@param label string
---@param action any
---@return wonderland.Element
local function entry(app, ctx, width, label, action)
	local theme = app.services.appearance.theme
	local row = sty():row():w(width):h(theme:px(44)):pad(0, theme:px(14), 0, theme:px(14)):align("center")
		:radius(theme:radius("sm"))
	return div()
		:style(row)
		:hover(
			sty()
				:row():w(width):h(theme:px(44)):pad(0, theme:px(14), 0, theme:px(14)):align("center")
				:radius(theme:radius("sm")):bg(theme:color("hover"))
		):onClick(action)
		:children(text(label):style(theme:s():wrel(1.0):text(theme:type("sm")):weight("medium"):fg(theme:color("text"))))
end

---@param app beat.App
---@param _overlay beat.OverlayInstance
---@param window wonderland.RenderWindow
---@return wonderland.Element
function mobileMenu.view(app, _overlay, window)
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local padding = theme:px(8)
	local width = math.min(theme:px(224), window.width - theme:px(24))
	local rowWidth = width - padding * 2
	local rows = {
		entry(app, ctx, rowWidth, "Settings", { type = "navigate", page = { kind = "settings" } }),
		entry(app, ctx, rowWidth, "Equalizer", { type = "open", overlay = "equalizer" })
	}
	-- The task list lived in the top bar a phone no longer has. It is here only while there is
	-- something to see, which is the same rule the bar's button followed.
	if #app.services.tasks:tasks() > 0 then
		rows[#rows + 1] = entry(app, ctx, rowWidth, "Tasks", { type = "open", overlay = "tasks" })
	end
	local height = padding * 2 + theme:px(44) * #rows + theme:px(2) * (#rows - 1)
	local x = window.width - width - theme:px(12)
	local y = window.height - metrics.bottomHeight(app, window.width) - height - theme:px(8)
	y = math.max(theme:px(8), y)

	local panel = div()
		:style(
			sty()
				:w(width):h(height):column():pad(padding):gap(theme:px(2)):radius(theme:radius("md"))
				:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
				:shadow(0, theme:px(12), theme:px(30), "#00000080")
		):onClick({ type = "keep" })
		:children(rows)

	return div()
		:style(sty():fill():offset(0, 0):z(130)):onClick({ type = "dismiss" })
		:children({ div():style(sty():w(width):h(height):offset(x, y)):children({ panel }) })
end

return mobileMenu
