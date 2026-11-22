-- The phone's bottom tabs. Search lives here as a destination as well as in the top bar, so a
-- thumb can reach every primary page without the desktop rail.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local cache = require("beat-ui.cache")
local metrics = require("beat.app.components.helpers.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local mobileNav = {}

-- The tabs the app navigates to, and what a tap says: the same tables on every frame.
local HOME = { kind = "home" }
local LIBRARY = { kind = "library" }
local SEARCH = { kind = "search" }
local PLAYLISTS = { kind = "playlists" }
local GO_HOME = { type = "navigate", page = HOME }
local GO_LIBRARY = { type = "navigate", page = LIBRARY }
local GO_SEARCH = { type = "navigate", page = SEARCH }
local GO_PLAYLISTS = { type = "navigate", page = PLAYLISTS }

-- What a tap on a plugin's destination says, by the registration that made it.
---@type table<beat.NavEntry, { type: string, page: beat.Route }>
local navMessages = setmetatable({}, { __mode = "k" })

---@param entry beat.NavEntry
---@return { type: string, page: beat.Route }
local function navMessage(entry)
	local message = navMessages[entry]
	if message == nil then
		message = { type = "navigate", page = entry.page }
		navMessages[entry] = message
	end
	return message
end

---@class beat.components.chrome.MobileTabStyles
---@field tab wonderland.StyleBuilder
---@field hover wonderland.StyleBuilder

---@param ctx beat.ui.Context
---@param tabWidth number
---@return beat.components.chrome.MobileTabStyles
local function tabStyles(ctx, tabWidth)
	return {
		tab = sty():w(tabWidth):hrel(1.0):column():align("center"):justify("center"):gap(2),
		hover = sty():w(tabWidth):hrel(1.0):column():align("center"):justify("center"):gap(2):bg(ctx:color("hover"))
	}
end

---@param ctx beat.ui.Context
---@param colour string
---@return wonderland.StyleBuilder
local function tabLabelStyle(ctx, colour)
	return ctx:s():text(ctx:type("xs")):weight("semibold"):fg(colour)
end

---@param ctx beat.ui.Context
---@param height number
---@param inset number # The navigation bar's height, which the tabs sit above
---@return wonderland.StyleBuilder
local function tabBarStyle(ctx, height, inset)
	return sty():row():wrel(1.0):h(height + inset):pad(0, 0, inset, 0):bg(ctx:color("surface"))
end

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
		{ kind = "home", icon = "home", label = "Home", route = HOME, message = GO_HOME },
		{ kind = "library", icon = "library", label = "Library", route = LIBRARY, message = GO_LIBRARY },
		{ kind = "search", icon = "search", label = "Search", route = SEARCH, message = GO_SEARCH },
		{ kind = "playlists", icon = "playlists", label = "Playlists", route = PLAYLISTS, message = GO_PLAYLISTS }
	}
	-- A plugin's destinations come after the app's own, in the order they asked for.
	for _, entry in ipairs(app.registry:nav()) do
		items[#items + 1] = { page = entry.page, icon = entry.icon, label = entry.title, message = navMessage(entry) }
	end
	local tabWidth = math.floor(width / #items)

	-- Every tab is the same cell, so the cell and its hover are one record of builders for the whole
	-- bar; only the glyph's colour and the label change with the destination.
	local set = cache.of(ctx, tabStyles, "mobileNav", tabWidth) --[[@as beat.components.chrome.MobileTabStyles]]

	local tabs = {}
	for _, item in ipairs(items) do
		local route = (item.route or item.page or { kind = item.kind }) --[[@as { kind: string, id: number? }]]
		local active
		if item.page ~= nil then
			active = app.page.kind == route.kind and (route.id == nil or app.page.id == route.id)
		else
			active = app.page.kind == item.kind or (item.kind == "search" and app.page.kind == "searchAll") or (item.kind == "playlists" and app.page.kind == "playlist")
		end
		local colour = active ? (theme:color("accent")) : (theme:color("muted"))
		local labelStyle = cache.of(ctx, tabLabelStyle, "mobileNavLabel", colour) --[[@as wonderland.StyleBuilder]]
		tabs[#tabs + 1] = div():style(set.tab):hover(set.hover):onClick(item.message):children({
			ui.icon(ctx, { name = item.icon, size = theme:px(21), colour = colour }),
			text(item.label):style(labelStyle)
		})
	end

	local _, inset = metrics.insets()
	local barStyle = cache.of(ctx, tabBarStyle, "mobileNavBar", height, inset) --[[@as wonderland.StyleBuilder]]

	return div():style(barStyle):children(tabs)
end

return mobileNav
