-- The phone's bottom tabs. Search lives here as a destination as well as in the top bar, so a
-- thumb can reach every primary page without the desktop rail.
local wonderland = require("wonderland")
local icon = require("beat.app.components.icon")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local mobileNav = {}

---@class beat.components.chrome.MobileNavProps
---@field width number # The window's width

---@param app beat.App
---@param props beat.components.chrome.MobileNavProps
---@return wonderland.Element
function mobileNav.view(app, props)
	local width = props.width
	local theme = app.services.appearance.theme
	local height = theme:px(58)
	local items = {
		{ kind = "home", icon = "home", label = "Home"},
		{ kind = "library", icon = "library", label = "Library"},
		{ kind = "search", icon = "search", label = "Search"},
		{ kind = "playlists", icon = "playlists", label = "Playlists"},
	}
	local tabWidth = math.floor(width / #items)
	local tabs = {}
	for _, item in ipairs(items) do
		local active = app.page.kind == item.kind
		or (item.kind == "search" and app.page.kind == "searchAll")
		or (item.kind == "playlists" and app.page.kind == "playlist")
		local colour = active and theme:color("accent") or theme:color("muted")
		tabs[#tabs + 1] = div()
		:style(sty():w(tabWidth):hrel(1.0):column():align("center"):justify("center"):gap(2))
		:hover(sty():w(tabWidth):hrel(1.0):column():align("center"):justify("center"):gap(2)
		:bg(theme:color("hover")))
		:onClick({ type = "navigate", page = { kind = item.kind}})
		:children({
			icon.view(app, { name = item.icon, size = theme:px(21), colour = colour }),
			text(item.label):style(theme:s():text(theme:type("xs")):weight("semibold"):fg(colour)),
		})
	end

	return div()
	:style(sty():row():wrel(1.0):h(height):bg(theme:color("surface")))
	:children(tabs)
end

return mobileNav
