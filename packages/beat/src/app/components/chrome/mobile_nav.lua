-- The phone's bottom tabs. Search lives here as a destination as well as in the top bar, so a
-- thumb can reach every primary page without the desktop rail.
local wonderland = require("wonderland")
local ui = require("beat-ui")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local mobileNav = {}

---@class beat.components.chrome.MobileNavProps
---@field width number # The window's width
---@field ui beat.ui.Context

---@param app beat.App
---@param props beat.components.chrome.MobileNavProps
---@return wonderland.Element
function mobileNav.view(app, props)
	local width = props.width
	local ctx = props.ui
	local theme = app.services.appearance.theme
	local height = theme:px(58)
	local items = {
		{ kind = "home", icon = "home", label = "Home" },
		{ kind = "library", icon = "library", label = "Library" },
		{ kind = "search", icon = "search", label = "Search" },
		{ kind = "playlists", icon = "playlists", label = "Playlists" }
	}
	-- A plugin's destinations come after the app's own, in the order they asked for.
	for _, entry in ipairs(app.registry:nav()) do
		items[#items + 1] = { page = entry.page, icon = entry.icon, label = entry.title }
	end
	local tabWidth = math.floor(width / #items)
	local tabs = {}
	for _, item in ipairs(items) do
		local route = (item.page or { kind = item.kind }) --[[@as { kind: string, id: number? }]]
		local active
		if item.page ~= nil then
			active = app.page.kind == route.kind and (route.id == nil or app.page.id == route.id)
		else
			active = app.page.kind == item.kind or (item.kind == "search" and app.page.kind == "searchAll") or (item.kind == "playlists" and app.page.kind == "playlist")
		end
		local colour = active ? (theme:color("accent")) : (theme:color("muted"))
		tabs[#tabs + 1] = div()
			:style(sty():w(tabWidth):hrel(1.0):column():align("center"):justify("center"):gap(2))
			:hover(sty():w(tabWidth):hrel(1.0):column():align("center"):justify("center"):gap(2):bg(theme:color("hover")))
			:onClick({ type = "navigate", page = route })
			:children(
				{
					ui.icon(ctx, { name = item.icon, size = theme:px(21), colour = colour }),
					text(item.label):style(theme:s():text(theme:type("xs")):weight("semibold"):fg(colour))
				}
			)
	end

	return div():style(sty():row():wrel(1.0):h(height):bg(theme:color("surface"))):children(tabs)
end

return mobileNav
