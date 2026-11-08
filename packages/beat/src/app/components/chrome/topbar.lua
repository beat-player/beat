-- The top bar: back and forward, the search field, and the way into settings.
local wonderland = require("wonderland")
local icon = require("beat.app.components.icon")
local iconButton = require("beat.app.components.icon_button")
local metrics = require("beat.app.components.helpers.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local topbar = {}

---@class beat.components.chrome.TopbarProps
---@field width number # The window's width

---@param app beat.App
---@param props beat.components.chrome.TopbarProps
---@return wonderland.Element
function topbar.view(app, props)
	local width = props.width
	local theme = app.services.appearance.theme
	local mobile = metrics.mobile(app, width)
	local focused = app.layoutPlugin ~= nil and app.window ~= nil and app.layoutPlugin:getFocusedId(app.window) == "search"
	local search = app.services.search.query
	local available = metrics.contentWidth(app, width)
	local leftWidth = available - (theme:px(mobile ? 48 : 44))
	local searchWidth = leftWidth - (theme:px(mobile ? 50 : 84))
	local pillHeight = (theme:px(mobile ? 38 : 34))
	local iconSize = (theme:px(mobile ? 40 : 32))

	local searchAreaWidth = searchWidth - theme:px(24) - theme:px(16) - theme:px(8) - (search ~= "" and theme:px(28) or 0)
	local searchArea = div():style(sty():w(searchAreaWidth):h(theme:px(32)):row():align("center"))
	local searchText = search ~= "" and search or (focused and " " or (width < 480 and "Search" or "Search artists, albums, tracks"))
	local searchColour = search ~= "" ? (theme:color("text")) : focused and (theme:color("text")) or (theme:color("faint"))
	local searchInput = div()
		:style(
			sty()
				:wrel(1.0):h(theme:px(32)):row():align("center"):pad(theme:px(10), 0, theme:px(10), 0):text(theme:type("sm"))
				:fg(theme:color("text"))
		):input({ name = "search", value = search, oninput = |value| -> { type = "search", value = value } })
	searchInput:children(text(searchText):style(theme:s():wrel(1.0):text(theme:type("sm")):fg(searchColour):ellipsis()))

	searchArea:children({ searchInput })

	local field = div()
		:style(sty():row():wrel(1.0):h(theme:px(32)):gap(theme:px(8)):align("center"))
		:children({ icon.view(app, { name = "search", size = theme:px(16), colour = theme:color("faint") }), searchArea })

	if search ~= "" then
		local closeColour = theme:color("muted")
		local closeWeight = math.max(1, theme:px(1.25))
		field:children(div():style(sty():size(theme:px(20), theme:px(20)):radius(theme:radius("full")):align("center"):justify("center")):onClick({ type = "search", value = "" }):canvas(function(canvas)
			local middleX, middleY = canvas.width / 2, canvas.height / 2
			local arm = math.max(3, theme:px(4))
			canvas:line(middleX - arm, middleY - arm, middleX + arm, middleY + arm, closeWeight, closeColour)
			canvas:line(middleX + arm, middleY - arm, middleX - arm, middleY + arm, closeWeight, closeColour)
		end))
	end

	---@param name string
	---@param action beat.Message
	---@param enabled boolean
	local function navButton(name, action, enabled)
		return iconButton.view(app, { name = name, size = iconSize, onClick = enabled and action or nil, active = enabled })
	end

	local searchStyle = sty()
		:row():w(searchWidth):h(pillHeight):radius(theme:radius("full"))
		:bg(focused ? (theme:color("hover")) : (theme:color("elevated"))):pad(0, theme:px(12), 0, theme:px(12))
		:align("center")

	local searchPill = div():style(searchStyle):children(field)
	if focused then
		-- A focus ring is painted over the pill rather than styled onto it: a border that takes
		-- part in layout shrinks the content box by a pixel and makes the field jump when focus
		-- arrives. The ring is outside the flow and the field keeps its exact position.
		searchPill:children(
			div()
				:style(
					sty()
						:w(searchWidth):h(pillHeight):radius(theme:radius("full")):border(theme:px(1), theme:color("accent"))
						:offset(-theme:px(12), 0)
				)
		)
	end

	local leftChildren = { navButton("chevronLeft", { type = "back" }, #app.history > 0) }
	if not mobile then
		leftChildren[#leftChildren + 1] = navButton("chevronRight", { type = "forward" }, #app.future > 0)
	end
	leftChildren[#leftChildren + 1] = searchPill
	local left = div()
		:style(sty():row():w(leftWidth):h(pillHeight):gap(theme:px(10)):align("center")):children(leftChildren)

	return div()
		:style(
			sty()
				:row():wrel(1.0):h(metrics.topbarHeight(app, width)):pad(0, metrics.pad(app, width), 0, metrics.pad(app, width))
				:gap(theme:px(10)):align("center"):justify("space-between")
		)
		:children(
			{
				left,
				iconButton.view(
					app,
					{ name = "settings", size = iconSize, onClick = { type = "navigate", page = { kind = "settings" } } }
				)
			}
		)
end

return topbar
