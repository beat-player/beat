-- The phone's own menu: the places the top bar no longer has room for in its corner. It pops up
-- out of the More tab, pointing at it, over the mini player rather than above it.
local wonderland = require("wonderland")
local metrics = require("beat.app.components.helpers.metrics")
local popup = require("beat.app.components.popup")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.MobileMenuOverlay: beat.OverlaySurface
local mobileMenu = { light = true }

-- The tab bar's own height, which the menu sits on; see `beat.components.chrome.mobileNav`.
local NAV_HEIGHT = 58
-- The More tab is the fifth of the app's tabs; plugins' tabs come after it.
local MORE_TAB = 5
local APP_TABS = 5

---@param app beat.App
function mobileMenu.new(app)
	popup.open(app, "mobileMenu")
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

	-- The menu stands on the tab bar, its point over the middle of the More tab, and as far right
	-- as the window lets it go while still covering that tab.
	local _, inset = metrics.insets()
	local navTop = window.height - theme:px(NAV_HEIGHT) - inset
	local tabWidth = math.floor(window.width / (APP_TABS + #app.registry:nav()))
	local tabCentre = (MORE_TAB - 0.5) * tabWidth
	local edge = theme:px(8)
	local x = math.max(edge, math.min(window.width - width - edge, tabCentre - width + theme:px(40)))
	local point = theme:px(8)
	local total = height + point
	local y = navTop - total - theme:px(2)

	local panel = div()
		:style(
			sty()
				:w(width):h(height):column():pad(padding):gap(theme:px(2)):radius(theme:radius("md"))
				:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
				:shadow(0, theme:px(12), theme:px(30), "#00000080")
		):onClick({ type = "keep" })
		:children(rows)

	-- The point under the panel, over the tab: what says which control the menu belongs to.
	local pointX = tabCentre - x
	local colour = theme:color("elevated")
	local arrow = div():style(sty():w(width):h(point)):canvas(function(canvas)
		canvas:polygon({ pointX - point, -1, pointX + point, -1, pointX, point }, colour)
	end)

	return div()
		:style(sty():fill():offset(0, 0):z(130)):onClick({ type = "dismiss" })
		:children(
			{
				popup.view(
					app,
					{
						key = "mobileMenu",
						panel = div():style(sty():column():w(width):h(total)):children({ panel, arrow }),
						x = x,
						y = y,
						width = width,
						height = total,
						grows = "up"
					}
				)
			}
		)
end

return mobileMenu
