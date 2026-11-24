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
local OPEN_MORE = { type = "open", overlay = "mobile_menu" }
local FOCUS_SEARCH = { type = "focusPageSearch" }

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

-- What the three dots are drawn from, written when the bar is built and read when the mark is
-- drawn: there is one More tab, and a closure made in the view is one the trace compiler gives up
-- on. The faces are the only two colours it takes.
local moreState = { size = 0, colour = "", accent = "", muted = "" }

---@param canvas wonderland.Canvas
local function drawMore(canvas)
	local size, colour = moreState.size, moreState.colour
	local radius = math.max(1.2, math.floor(size * 0.08))
	local y = math.floor(canvas.height / 2 - radius)
	local step = size * 0.26
	local middle = math.floor(canvas.width / 2 - radius)
	local back, ahead = math.floor(middle - step), math.floor(middle + step)
	canvas:rect(back, y, radius * 2, radius * 2, colour, radius)
	canvas:rect(middle, y, radius * 2, radius * 2, colour, radius)
	canvas:rect(ahead, y, radius * 2, radius * 2, colour, radius)
end

-- The mark's box at one size, kept for the bars built every frame.
---@type table<number, wonderland.StyleBuilder>
local moreBoxes = {}

---@param size number
---@return wonderland.StyleBuilder
local function moreBox(size)
	local box = moreBoxes[size]
	if box == nil then
		box = sty():size(size, size)
		moreBoxes[size] = box
	end
	return box
end

-- What a tab's glyph is asked for, written again for each tab: the icon reads it and keeps
-- nothing, and the bar is built on every frame.
---@type table<string, any>
local iconProps = {}

-- The five destinations the app always has, in the order they appear. They are plain records, so
-- the bar walks them rather than making a list of them again per frame.
local OWN_ITEMS = {
	{ kind = "home", icon = "home", label = "Home", message = GO_HOME },
	{ kind = "library", icon = "library", label = "Library", message = GO_LIBRARY },
	{ kind = "playlists", icon = "playlists", label = "Playlists", message = GO_PLAYLISTS },
	{ kind = "search", icon = "search", label = "Search", message = GO_SEARCH },
	{ kind = "more", icon = "more", label = "More", message = OPEN_MORE }
}

-- A plugin's destination as the bar sees it, made once per registration: only the page it opens
-- changes with the route the plugin asked for.
---@type table<beat.NavEntry, { page: beat.Route, icon: string, label: string, message: table }>
local pluginItems = setmetatable({}, { __mode = "k" })

---@param entry beat.NavEntry
---@return table
local function pluginItem(entry)
	local item = pluginItems[entry]
	if item == nil then
		item = { page = entry.page, icon = entry.icon, label = entry.title, message = navMessage(entry) }
		pluginItems[entry] = item
	end
	return item
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

--- One tab of the bar: the same cell for every destination, the mark and the word for this one.
---@param app beat.App
---@param ctx beat.ui.Context
---@param theme beat.Theme
---@param set beat.components.chrome.MobileTabStyles
---@param item table
---@param page beat.Route?
---@return wonderland.Element
local function tabElement(app, ctx, theme, set, item, page)
	local active
	if page ~= nil then
		---@cast page { kind: string, id: number? }
		active = app.page.kind == page.kind and (page.id == nil or app.page.id == page.id)
	elseif item.kind == "more" then
		active = app:overlay("mobile_menu") ~= nil
	else
		active = app.page.kind == item.kind
			or (item.kind == "search" and app.page.kind == "searchAll")
			or (item.kind == "playlists" and app.page.kind == "playlist")
	end
	local colour = active ? (theme:color("accent")) : (theme:color("muted"))
	local labelStyle = cache.of(ctx, tabLabelStyle, "mobileNavLabel", colour) --[[@as wonderland.StyleBuilder]]
	local mark
	if item.kind == "more" then
		local size = theme:px(21)
		moreState.size, moreState.colour = size, colour
		mark = div():style(moreBox(size)):canvas(drawMore)
	else
		iconProps.name, iconProps.size, iconProps.colour = item.icon, theme:px(21), colour
		mark = ui.icon(ctx, iconProps --[[@as beat.ui.IconProps]])
	end
	-- Search already showing asks for its field rather than for the page again.
	local action = item.kind == "search" and app.page.kind == "search" and FOCUS_SEARCH or item.message
	return div():style(set.tab):hover(set.hover):onClick(action):children(mark, text(item.label):style(labelStyle))
end

--- The bar's tabs, added to it one at a time. The loop is its own function so the trace that
--- builds the bar does not start in it and leave it, which kept the nav's view interpreted.
---@param app beat.App
---@param ctx beat.ui.Context
---@param theme beat.Theme
---@param set beat.components.chrome.MobileTabStyles
---@param bar wonderland.Element
---@param destinations beat.NavEntry[]
local function addTabs(app, ctx, theme, set, bar, destinations)
	for at = 1, #OWN_ITEMS do
		bar:children(tabElement(app, ctx, theme, set, OWN_ITEMS[at]))
	end
	for at = 1, #destinations do
		local item = pluginItem(destinations[at])
		bar:children(tabElement(app, ctx, theme, set, item, item.page))
	end
end

---@param app beat.App
---@param props beat.components.chrome.MobileNavProps
---@return wonderland.Element
function mobileNav.view(app, props)
	local width = props.width
	local ctx = props.ui
	local theme = app.services.appearance.theme
	local height = theme:px(58)
	local destinations = app.registry:nav()
	local tabWidth = math.floor(width / (#OWN_ITEMS + #destinations))

	-- Every tab is the same cell, so the cell and its hover are one record of builders for the whole
	-- bar; only the glyph's colour and the label change with the destination.
	local set = cache.of(ctx, tabStyles, "mobileNav", tabWidth) --[[@as beat.components.chrome.MobileTabStyles]]
	local _, inset = metrics.insets()
	local barStyle = cache.of(ctx, tabBarStyle, "mobileNavBar", height, inset) --[[@as wonderland.StyleBuilder]]

	local bar = div():style(barStyle)
	addTabs(app, ctx, theme, set, bar, destinations)
	return bar
end

return mobileNav
