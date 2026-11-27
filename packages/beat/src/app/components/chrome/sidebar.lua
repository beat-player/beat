-- The rail down the left edge: where the app navigates from, the playlists played last, and the
-- name a row gives back while the pointer is on it.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local cache = require("beat-ui.cache")
local logo = require("beat.app.components.logo")
local format = require("beat.app.components.helpers.format")
local metrics = require("beat.app.components.helpers.metrics")
local measure = require("beat.app.components.helpers.measure")
local PlaylistArt = require("beat.app.components.playlist_art")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local sidebar = {}

-- The rail's own destinations and what a click on them says: the same tables on every frame.
local ROUTE_HOME = { kind = "home" }
local ROUTE_LIBRARY = { kind = "library" }
local ROUTE_PLAYLISTS = { kind = "playlists" }
local GO_HOME = { type = "navigate", page = ROUTE_HOME }
local GO_LIBRARY = { type = "navigate", page = ROUTE_LIBRARY }
local GO_PLAYLISTS = { type = "navigate", page = ROUTE_PLAYLISTS }
local TOGGLE_SIDEBAR = { type = "toggleSidebar" }
local NEW_PLAYLIST = { type = "open", overlay = "playlist_dialog", smart = false }

-- What a click on a playlist row says, by its id: the recent list is the same rows for as long as
-- the playlist is, and the id is what the message names.
---@type table<number, { type: string, page: { kind: string, id: number } }>
local playlistMessages = {}

---@param playlist beat.Playlist
---@return { type: string, page: { kind: string, id: number } }
local function playlistMessage(playlist)
	local message = playlistMessages[playlist.id]
	if message == nil then
		message = { type = "navigate", page = { kind = "playlist", id = playlist.id } }
		playlistMessages[playlist.id] = message
	end
	return message
end

-- What a click on a plugin's destination says, by the registration that made it.
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

-- The rail's own destinations: the same three records on every frame. A plugin's destination is
-- made once per registration, since only the page it opens comes from the plugin.
---@type table[]
local BUILTIN_NAV = {
	{ kind = "home", icon = "home", label = "Home", route = ROUTE_HOME, message = GO_HOME },
	{ kind = "library", icon = "library", label = "Library", route = ROUTE_LIBRARY, message = GO_LIBRARY },
	{ kind = "playlists", icon = "playlists", label = "Playlists", route = ROUTE_PLAYLISTS, message = GO_PLAYLISTS }
}

---@type table<beat.NavEntry, { page: beat.Route, icon: string, label: string, message: table }>
local pluginNav = setmetatable({}, { __mode = "k" })

-- How many playlists the rail shows under its header.
local RECENT_PLAYLISTS = 3

---@class beat.components.chrome.SidebarCreateStyles
---@field base wonderland.StyleBuilder
---@field hover wonderland.StyleBuilder
---@field iconBox wonderland.StyleBuilder
---@field label wonderland.StyleBuilder

---@class beat.components.chrome.SidebarHeaderStyles
---@field row wonderland.StyleBuilder
---@field text wonderland.StyleBuilder

-- How much room a label needs before it is drawn -- the leading mark, the gap beside it and the
-- label's own ink -- and the room it gains before it is fully visible. Between the two it fades,
-- so a label does not pop on at a threshold.
local LABEL_FADE = 24
local ALPHA_STEPS = 8

---@param room number # The content box the label shares with its leading mark
---@param needed number # The leading mark, its gap and the label's ink
---@return number # 0 while the label does not fit, then eighths up to 1
local function labelAlpha(room, needed)
	if room < needed then return 0 end
	local alpha = (room - needed) / LABEL_FADE
	if alpha > 1 then alpha = 1 end
	return math.floor(alpha * ALPHA_STEPS + 0.5) / ALPHA_STEPS
end

-- What the rail's boxes are built from: the theme and a handful of numbers. Each is a module-level
-- function so a frame asks the cache for the record it needs and builds nothing.
--
-- A label is given the width its ink needs, or the room it has when that is less, and ellipsizes
-- there: a row's contents then end inside the row's own hover box whatever the rail's width is,
-- rather than being laid out wider than the box they are drawn over.
---@param ctx beat.ui.Context
---@param fg string
---@param alpha number
---@param width number
---@return wonderland.StyleBuilder
local function navLabelStyle(ctx, fg, alpha, width)
	return ctx:s():w(width):text(ctx:type("base")):weight("semibold"):fg(ctx:color(fg, alpha)):ellipsis()
end

---@param ctx beat.ui.Context
---@param alpha number
---@param width number
---@return wonderland.StyleBuilder
local function brandTextStyle(ctx, alpha, width)
	return ctx:s():w(width):text(ctx:type("xl")):weight("bold"):fg(ctx:color("text", alpha)):ellipsis()
end

---@param ctx beat.ui.Context
---@param pad number
---@return wonderland.StyleBuilder
local function brandBoxStyle(ctx, pad)
	return sty():row():wrel(1.0):h(ctx:px(52)):gap(ctx:px(10)):align("center"):pad(0, pad, 0, pad)
end

---@param ctx beat.ui.Context
---@param alpha number
---@param width number
---@return wonderland.StyleBuilder
local function countTextStyle(ctx, alpha, width)
	return ctx:s():w(width):text(ctx:type("xs")):fg(ctx:color("faint", alpha)):ellipsis()
end

---@param ctx beat.ui.Context
---@param rowHeight number
---@param artSize number
---@param alpha number
---@param pad number
---@param labelWidth number
---@return beat.components.chrome.SidebarCreateStyles
local function createStyles(ctx, rowHeight, artSize, alpha, pad, labelWidth)
	local radius = ctx:radius("sm")
	local base = sty()
		:row():wrel(1.0):h(rowHeight):gap(ctx:px(10)):align("center"):radius(radius):bg(ctx:color("accent", 0.13))
	local hover = sty()
		:row():wrel(1.0):h(rowHeight):gap(ctx:px(10)):align("center"):radius(radius):bg(ctx:color("accent", 0.22))
	base:pad(0, pad, 0, pad)
	hover:pad(0, pad, 0, pad)
	return {
		base = base,
		hover = hover,
		iconBox = sty():size(artSize, artSize):radius(radius):bg(ctx:color("accent", 0.18)):align("center"):justify("center"),
		label = ctx:s():w(labelWidth):text(ctx:type("sm")):weight("semibold"):fg(ctx:color("accent", alpha)):ellipsis()
	}
end

-- The same faces without a width, for asking the font manager how much a label's ink takes. The
-- text plugin measures the run it would draw, and the answer is cached by the style's slot, so a
-- frame asks again for a table lookup rather than a measurement.
---@param ctx beat.ui.Context
---@return wonderland.StyleBuilder
local function navMeasureStyle(ctx)
	return ctx:s():text(ctx:type("base")):weight("semibold")
end

---@param ctx beat.ui.Context
---@return wonderland.StyleBuilder
local function brandMeasureStyle(ctx)
	return ctx:s():text(ctx:type("xl")):weight("bold")
end

---@param ctx beat.ui.Context
---@return wonderland.StyleBuilder
local function countMeasureStyle(ctx)
	return ctx:s():text(ctx:type("xs"))
end

---@param ctx beat.ui.Context
---@return wonderland.StyleBuilder
local function createMeasureStyle(ctx)
	return ctx:s():text(ctx:type("sm")):weight("semibold")
end

--- How much room a label's ink takes: the font manager's answer once a window has one, and the
--- codepoint estimate before that.
---@param app beat.App
---@param value string
---@param style wonderland.StyleBuilder
---@param size number
---@param latin number
---@return number
local function inkWidth(app, value, style, size, latin)
	return measure.width(app, value, style) or measure.estimate(value, size, latin)
end

--- How far the rail is from its narrow form: 0 while it is collapsed, 1 at the width the settings
--- ask for. It is read from the width itself, so a row's inset follows the same eased steps as the
--- rail and an icon travels from the rail's middle to its left edge as the rail opens.
---@param side number
---@param collapsedWidth number
---@param expandedWidth number
---@return number
local function openShare(side, collapsedWidth, expandedWidth)
	local span = expandedWidth - collapsedWidth
	if span <= 0 then return 1 end
	local open = (side - collapsedWidth) / span
	if open < 0 then
		return 0
	elseif open > 1 then
		return 1
	end
	return open
end

--- A row's horizontal inset: the inset that centres its content in the narrow rail, the expanded
--- row's own inset, and the width's progress between the two. Whole pixels, because a style's
--- padding is an integer and a half one would only move the content half a pixel off centre.
---@param side number
---@param railPad number
---@param content number
---@param expanded number
---@param open number
---@return number
local function rowInset(side, railPad, content, expanded, open)
	local centred = math.floor((side - railPad * 2 - content) / 2)
	if centred < 0 then centred = 0 end
	return math.floor(centred + (expanded - centred) * open + 0.5)
end

---@param ctx beat.ui.Context
---@param side number
---@return wonderland.StyleBuilder
local function railStyle(ctx, side)
	return sty():w(side):hrel(1.0):column():pad(0, ctx:px(16), 0, ctx:px(16)):gap(ctx:px(4)):bg(ctx:color("sidebar"))
end

---@param ctx beat.ui.Context
---@return wonderland.StyleBuilder
local function separatorStyle(ctx)
	return sty():h(1):bg(ctx:color("border"))
end

---@param ctx beat.ui.Context
---@param navHeight number
---@return wonderland.StyleBuilder
local function navAreaStyle(ctx, navHeight)
	return sty():column():h(navHeight):gap(ctx:px(2)):pad(ctx:px(10), 0, 0, 0)
end

---@param ctx beat.ui.Context
---@return wonderland.StyleBuilder
local function spacerStyle(ctx)
	return sty():h(ctx:px(16))
end

---@param ctx beat.ui.Context
---@return wonderland.StyleBuilder
local function headBoxStyle(ctx)
	return sty():column():h(ctx:px(28))
end

---@param ctx beat.ui.Context
---@param alpha number
---@return beat.components.chrome.SidebarHeaderStyles
local function headerStyles(ctx, alpha)
	return {
		row = sty():row():wrel(1.0):h(ctx:px(24)):align("center"):justify("space-between"),
		text = ctx:s():text(ctx:type("xs")):weight("bold"):fg(ctx:color("text", alpha))
	}
end

---@param ctx beat.ui.Context
---@param listHeight number
---@param rowGap number
---@return wonderland.StyleBuilder
local function listBoxStyle(ctx, listHeight, rowGap)
	return sty():column():h(listHeight):gap(rowGap)
end

---@param ctx beat.ui.Context
---@return wonderland.StyleBuilder
local function tooltipMeasureStyle(ctx)
	return ctx:s():text(ctx:type("sm")):weight("semibold")
end

---@param ctx beat.ui.Context
---@param boxWidth number
---@return wonderland.StyleBuilder
local function tooltipBoxStyle(ctx, boxWidth)
	return sty()
		:w(boxWidth):h(ctx:px(30)):row():align("center"):pad(0, ctx:px(8), 0, ctx:px(8)):radius(ctx:radius("sm"))
		:bg(ctx:color("elevated")):border(ctx:px(1), ctx:color("border")):shadow(0, ctx:px(4), ctx:px(14), "#00000099")
end

---@param ctx beat.ui.Context
---@param nameWidth number
---@return wonderland.StyleBuilder
local function tooltipNameStyle(ctx, nameWidth)
	return ctx:s():w(nameWidth):text(ctx:type("sm")):weight("semibold"):fg(ctx:color("text"))
end

--- The tooltip's arrow, pointing up at the row, filled with the panel's own colour.
---@param colour string
---@return fun(canvas: wonderland.Canvas)
local function tooltipArrowDraw(colour)
	return function(canvas) canvas:polygon({ 0, 0, canvas.width, 0, canvas.width / 2, canvas.height }, colour) end
end

---@class beat.components.chrome.SidebarArrowStyles
---@field style wonderland.StyleBuilder
---@field draw fun(canvas: wonderland.Canvas)

---@param ctx beat.ui.Context
---@return beat.components.chrome.SidebarArrowStyles
local function tooltipArrowStyles(ctx)
	return { style = sty():w(ctx:px(14)):h(ctx:px(7)), draw = tooltipArrowDraw(ctx:color("elevated")) }
end

---@param ctx beat.ui.Context
---@param wrapperX number
---@param wrapperY number
---@param artWidth number
---@param totalHeight number
---@return wonderland.StyleBuilder
local function tooltipWrapperStyle(ctx, wrapperX, wrapperY, artWidth, totalHeight)
	return sty():w(artWidth):h(totalHeight):offset(wrapperX, wrapperY):z(80):column():align("center")
end

--- The rail's width for this frame: the width the settings and the window ask for, eased while
--- the rail opens or closes. The grip's own dragging is not eased -- see the service -- and the
--- reduce-motion setting settles every transition at once.
---@param app beat.App
---@param windowWidth number
---@param now number?
---@return number
function sidebar.width(app, windowWidth, now)
	local target = metrics.sidebarWidth(app, windowWidth)
	local values = app.services.settings.values
	local collapsed = values.sidebarCollapsed or windowWidth < app.services.appearance.theme:px(1040)
	return app.services.sidebar:width(target, collapsed, now or wonderland.time.now())
end

---@class beat.components.chrome.SidebarProps
---@field width number # The window's width
---@field height number # The room the rail has
---@field ui beat.ui.Context
---@field side number? # The rail's width this frame, when the shell has already asked

-- The rail's hit test and its resize grip are messages about where things are, which changes with
-- the window and the playlists, not with the frame. Wonderland is handed the same function every
-- frame and it reads the geometry the frame that drew the rail left here.
---@class beat.components.chrome.SidebarGeometry
---@field listTop number
---@field rowStep number
---@field rowHeight number
---@field artSize number
---@field artX number
---@field playlists beat.Playlist[]?
---@field nav table[]? # The rail's rows, until the registry's list changes
---@field navSource beat.NavEntry[]? # The registry's cached list the rows were built from
---@field recent beat.Playlist[]? # The playlists under the header, until the taxonomy changes
---@field recentTaxonomy beat.Taxonomy? # The taxonomy that list was asked of
---@field recentRevision number? # The taxonomy revision they were asked at
---@field hover (fun(x: number?, relY: number): any)?
---@field resize (fun(size: number): any)?

---@type table<beat.App, beat.components.chrome.SidebarGeometry>
local geometry = setmetatable({}, { __mode = "k" })

---@param app beat.App
---@return beat.components.chrome.SidebarGeometry
local function stateOf(app)
	local state = geometry[app]
	if state == nil then
		state = { listTop = 0, rowStep = 1, rowHeight = 0, artSize = 0, artX = 0 }
		geometry[app] = state
	end
	return state
end

--- The rail's rows: the built-in destinations then the plugin ones. The registry hands back its
--- cached list, so comparing that record says a registration was made or a plugin switched off;
--- between those, the same array is drawn and a frame builds no row.
---@param app beat.App
---@param state beat.components.chrome.SidebarGeometry
---@return table[]
local function navOf(app, state)
	local source = app.registry:nav()
	if state.navSource == source and state.nav ~= nil then return state.nav end

	local nav = {}
	for at = 1, #BUILTIN_NAV do nav[at] = BUILTIN_NAV[at] end
	for at = 1, #source do
		local entry = source[at]
		local item = pluginNav[entry]
		if item == nil then
			item = { page = entry.page, icon = entry.icon, label = entry.title, message = navMessage(entry) }
			pluginNav[entry] = item
		end
		nav[#nav + 1] = item
	end
	state.nav, state.navSource = nav, source
	return nav
end

--- The playlists the rail lists, kept until the taxonomy changes: the service's recent order is
--- sorted once per revision, but the list it hands back is a new array on every call, and a frame
--- asks once.
---@param app beat.App
---@param state beat.components.chrome.SidebarGeometry
---@return beat.Playlist[]
local function recentPlaylists(app, state)
	local taxonomy = app.services.collections.taxonomy
	if
		state.recent ~= nil
		and state.recentTaxonomy == taxonomy
		and state.recentRevision == taxonomy.revision
	then
		return state.recent
	end

	local list = app.services.collections:recentPlaylists(RECENT_PLAYLISTS)
	state.recent, state.recentTaxonomy, state.recentRevision = list, taxonomy, taxonomy.revision
	return list
end

---@param app beat.App
---@param relY number
---@return { type: string, id: number?, y: number?, top: number?, x: number?, height: number? }?
local function hoverMessage(app, relY)
	local state = stateOf(app)
	local listTop, rowStep, rowHeight = state.listTop, state.rowStep, state.rowHeight
	---@type beat.Playlist[]
	local playlists = state.playlists or {}
	local offset = relY - listTop
	local hovered = nil
	if offset >= 0 then
		local index = math.floor(offset / rowStep) + 1
		local within = offset - (index - 1) * rowStep
		if index <= #playlists and within < rowHeight then
			local rowTop = listTop + (index - 1) * rowStep
			hovered = {
				id = playlists[index].id,
				y = rowTop + rowHeight / 2,
				-- The arrow meets the artwork's top edge, not the taller hover row around it.
				top = rowTop + (rowHeight - state.artSize) / 2,
				x = state.artX,
				height = state.artSize
			}
		end
	end

	-- A message is a frame: moving inside one row, or over anything that has no shortcut, asks for
	-- nothing when the tooltip is already in the state that movement means.
	local old = app.services.sidebar.hover
	if hovered == nil then
		if old == nil then return nil end
		return { type = "hoverPlaylist", id = nil }
	end
	if old ~= nil and old.id == hovered.id and old.y == hovered.y and old.top == hovered.top and old.x == hovered.x then
		return nil
	end
	return {
		type = "hoverPlaylist",
		id = hovered.id,
		y = hovered.y,
		top = hovered.top,
		x = hovered.x,
		height = hovered.height
	}
end

--- The pointer handler of one app. Made here so the frame that draws the rail defines no function.
---@param app beat.App
---@return fun(x: number?, relY: number): any
local function hoverHandler(app)
	return |_, relY| -> hoverMessage(app, tonumber(relY) or 0)
end

--- The resize handler of one app: it reads the theme's scale as it is when the grip is dragged.
---@param app beat.App
---@return fun(size: number): any
local function resizeHandler(app)
	return size -> { type = "sidebarWidth", width = size / app.services.appearance.theme.scale }
end

--- The two callbacks the rail hands wonderland, made once per app: one reads the frame's geometry,
--- the other the theme's scale as it is when the grip is dragged.
---@param app beat.App
---@return table<string, any>
local function handlersOf(app)
	local state = stateOf(app)
	if state.hover == nil then
		state.hover, state.resize = hoverHandler(app), resizeHandler(app)
	end
	return state
end

local function ignoreMouseMove()
	return nil
end

-- The keys the rail's rows keep their press marks by: a row is named by what it opens rather than
-- by the place it has in the rail, so the mark of a tap stays on it while the page it opened slides
-- in. Made once per destination, so a frame of the rail allocates no key string.
---@type table<string, string>
local navKeys = {}
---@type table<number, string>
local playlistKeys = {}

---@param kind string
---@return string
local function navKey(kind)
	local key = navKeys[kind]
	if key == nil then
		key = "sidebar.nav." .. kind
		navKeys[kind] = key
	end
	return key
end

---@param id number
---@return string
local function playlistKey(id)
	local key = playlistKeys[id]
	if key == nil then
		key = "sidebar.playlist." .. id
		playlistKeys[id] = key
	end
	return key
end

---@param app beat.App
---@param props beat.components.chrome.SidebarProps
---@return wonderland.Element
function sidebar.view(app, props)
	local width, height = props.width, props.height
	local ctx = props.ui
	local theme = app.services.appearance.theme
	-- The rail is sized once for both this view and the shell's content box: the caller passes the
	-- width it already asked for so the two cannot land on either side of an animation step.
	local side = props.side or sidebar.width(app, width)
	local current = app.page
	local state = stateOf(app)

	-- The rail's rows: the app's own three and the plugin destinations, rebuilt only when the
	-- registry's list changes rather than on every frame it draws them.
	local nav = navOf(app, state)

	-- The rail's own inset and the width it has to draw in. `open` is how far it is from the narrow
	-- form, read from the width the animation is already at, so every row's inset moves with the
	-- same eased steps as the rail itself.
	local railPad = theme:px(16)
	local rowPad = theme:px(10)
	local collapsedWidth = theme:px(76)
	local expandedWidth = theme:px(app.services.settings.values.sidebarWidth or 264)
	if expandedWidth <= collapsedWidth then expandedWidth = collapsedWidth + 1 end
	local open = openShare(side, collapsedWidth, expandedWidth)
	local inner = side - railPad * 2

	local navIcon = theme:px(19)
	local navGap = theme:px(12)
	local navPad = rowInset(side, railPad, navIcon, rowPad, open)
	local navRoom = inner - navPad * 2
	local baseInk = theme:type("base")
	local smallInk = theme:type("xs")
	local smallLatin = 0.52
	local navMeasure = cache.of(ctx, navMeasureStyle, "sidebarNavMeasure") --[[@as wonderland.StyleBuilder]]

	local navRowHeight = theme:px(42)
	local navHeight = navRowHeight * #nav + math.max(0, #nav - 1) * theme:px(2) + theme:px(20)
	local navChildren = {}
	for _, item in ipairs(nav) do
		local route = (item.route or item.page) --[[@as { kind: string, id: number? }]]
		local active = current.kind == route.kind and (route.id == nil or current.id == route.id)
		local token = active and "text" or "muted"

		local rowChildren = {
			ui.icon(ctx, { name = item.icon, size = navIcon, colour = active ? (theme:color("accent")) : (theme:color(token)) })
		}
		local ink = inkWidth(app, item.label, navMeasure, baseInk, smallLatin)
		local room = navRoom - navIcon - navGap
		local alpha = labelAlpha(navRoom, navIcon + navGap + ink)
		if alpha > 0 then
			local labelStyle = cache.of(ctx, navLabelStyle, "sidebarNavLabel", token, alpha, math.min(room, ink)) --[[@as wonderland.StyleBuilder]]
			rowChildren[#rowChildren + 1] = text(item.label):style(labelStyle)
		end

		navChildren[#navChildren + 1] = ui.listRow(ctx, {
			height = navRowHeight,
			gap = navGap,
			padding = navPad,
			-- The narrow rail has no label and the glyph is centred in it; the wide one lays the
			-- row out from its left inset.
			justify = open <= 0 and "center" or nil,
			active = active,
			key = navKey(route.kind),
			onClick = item.message,
			children = rowChildren
		})
	end

	local brandMark = theme:px(22)
	local brandGap = theme:px(10)
	local brandPad = rowInset(side, railPad, brandMark, 0, open)
	local brandRoom = inner - brandPad * 2
	local brandChildren = { logo.view(app, { size = brandMark, colour = theme:color("accent") }) }
	local brandMeasure = cache.of(ctx, brandMeasureStyle, "sidebarBrandMeasure") --[[@as wonderland.StyleBuilder]]
	local brandInk = inkWidth(app, "beat", brandMeasure, theme:type("xl"), smallLatin)
	local brandAlpha = labelAlpha(brandRoom, brandMark + brandGap + brandInk)
	if brandAlpha > 0 then
		local width = math.min(brandRoom - brandMark - brandGap, brandInk)
		local brandText = cache.of(ctx, brandTextStyle, "sidebarBrandText", brandAlpha, width) --[[@as wonderland.StyleBuilder]]
		brandChildren[#brandChildren + 1] = text("beat"):style(brandText)
	end
	local brandStyle = cache.of(ctx, brandBoxStyle, "sidebarBrand", brandPad) --[[@as wonderland.StyleBuilder]]

	local rowGap = theme:px(3)
	local sectionGap = theme:px(4)
	local playlists = recentPlaylists(app, state)
	local rowCount = #playlists + 1
	local headerHeight = theme:px(24)
	-- The sidebar gaps and the header are style values, so the hover hit test can be the rows'
	-- own geometry without asking the layout that has not run yet. The header keeps its room even
	-- while its label is hidden, so a label fading in does not move the rows under it.
	local sectionTop = theme:px(52) + theme:px(1) + theme:px(16) + theme:px(1) + navHeight + theme:px(4) * 5
	local sectionInset = headerHeight + sectionGap
	local available = height - sectionTop - sectionInset
	local baseRowHeight = theme:px(52)
	local rowHeight = math.min(
		baseRowHeight,
		math.max(theme:px(36), math.floor((available - (rowCount - 1) * rowGap) / rowCount))
	)
	-- The expanded rail's artwork, and the smaller square the narrow rail has room for: its hover box
	-- is 44 px wide there, so the art keeps the same 6 px of background around it that a navigation
	-- row's glyph has. Between the two forms it grows with the rail's own eased progress, a whole
	-- pixel at a time, so a frame asks for one of a handful of artwork sizes.
	local expandedArt = math.min(theme:px(40), rowHeight - theme:px(8))
	local collapsedArt = math.min(expandedArt, collapsedWidth - railPad * 2 - theme:px(12))
	local artSize = math.floor(collapsedArt + (expandedArt - collapsedArt) * open + 0.5)
	local playGap = theme:px(10)
	local playPad = rowInset(side, railPad, artSize, rowPad, open)
	local playRoom = inner - playPad * 2
	local rowStep = rowHeight + rowGap
	local listTop = sectionTop + sectionInset
	local rows = {}
	local countMeasure = cache.of(ctx, countMeasureStyle, "sidebarCountMeasure") --[[@as wonderland.StyleBuilder]]

	for _, playlist in ipairs(playlists) do
		local tracks = PlaylistArt.tracks(app, playlist)
		local active = current.kind == "playlist" and current.id == playlist.id
		local rowChildren = { PlaylistArt.view(app, { tracks = tracks, size = artSize, name = playlist.name, ui = ctx }) }
		local count = format.count(#tracks, "track")
		local ink = inkWidth(app, count, countMeasure, smallInk, smallLatin)
		local alpha = labelAlpha(playRoom, artSize + playGap + ink)
		if alpha > 0 then
			local width = math.min(playRoom - artSize - playGap, ink)
			local countStyle = cache.of(ctx, countTextStyle, "sidebarCount", alpha, width) --[[@as wonderland.StyleBuilder]]
			rowChildren[#rowChildren + 1] = text(count):style(countStyle)
		end

		-- A row that is not being pointed at says nothing; the tooltip is where a playlist gets
		-- its name back. The list's own hit test is what knows which row the pointer is over.
		rows[#rows + 1] = ui.listRow(ctx, {
			height = rowHeight,
			gap = playGap,
			-- The same inset as the navigation and create rows: the artwork lines up with
			-- their icons instead of sitting flush against the rail's own padding.
			padding = playPad,
			justify = "space-between",
			active = active,
			key = playlistKey(playlist.id),
			onClick = playlistMessage(playlist),
			children = rowChildren
		})
	end

	-- The create row's geometry is the playlist rows' height and artwork, so the two read as one
	-- list: one record of builders per size and label opacity the rail comes to.
	local createMeasure = cache.of(ctx, createMeasureStyle, "sidebarCreateMeasure") --[[@as wonderland.StyleBuilder]]
	local createInk = inkWidth(app, "New playlist", createMeasure, theme:type("sm"), smallLatin)
	local createAlpha = labelAlpha(playRoom, artSize + playGap + createInk)
	local createWidth = math.min(playRoom - artSize - playGap, createInk)
	local createSet = cache.of(
		ctx,
		createStyles,
		"sidebarCreate",
		rowHeight,
		artSize,
		createAlpha,
		playPad,
		math.max(0, createWidth)
	) --[[@as beat.components.chrome.SidebarCreateStyles]]

	local createChildren = {
		div()
			:style(createSet.iconBox)
			:children(ui.icon(ctx, { name = "add", size = theme:px(18), colour = theme:color("accent") }))
	}
	if createAlpha > 0 then createChildren[#createChildren + 1] = text("New playlist"):style(createSet.label) end
	local create = ui.ripple(
		div():style(createSet.base):hover(createSet.hover):onClick(NEW_PLAYLIST):children(createChildren),
		nil,
		theme:color("text")
	)
	rows[#rows + 1] = create

	local listHeight = #rows * rowHeight + math.max(0, #rows - 1) * rowGap

	local handlerState = handlersOf(app)
	handlerState.listTop, handlerState.rowStep, handlerState.rowHeight = listTop, rowStep, rowHeight
	handlerState.playlists, handlerState.artSize = playlists, artSize
	handlerState.artX = railPad + playPad + artSize / 2

	-- The rail and the dividers are one size per theme: the width the rail is the only thing that
	-- changes with the window.
	local rail = cache.of(ctx, railStyle, "sidebarRoot", side) --[[@as wonderland.StyleBuilder]]
	local separator = cache.of(ctx, separatorStyle, "sidebarSeparator") --[[@as wonderland.StyleBuilder]]
	local navArea = cache.of(ctx, navAreaStyle, "sidebarNavArea", navHeight) --[[@as wonderland.StyleBuilder]]
	local spacer = cache.of(ctx, spacerStyle, "sidebarSpacer") --[[@as wonderland.StyleBuilder]]
	local head = cache.of(ctx, headBoxStyle, "sidebarHead") --[[@as wonderland.StyleBuilder]]
	-- The heading's run: the rail's own inset on both sides, then the ink.
	local headerAlpha = labelAlpha(inner, measure.estimate("Playlists", smallInk, smallLatin))
	local headers = cache.of(ctx, headerStyles, "sidebarHeader", headerAlpha) --[[@as beat.components.chrome.SidebarHeaderStyles]]
	local header = div():style(headers.row)
	if headerAlpha > 0 then header:children({ text("Playlists"):style(headers.text) }) end
	local listBox = cache.of(ctx, listBoxStyle, "sidebarList", listHeight, rowGap) --[[@as wonderland.StyleBuilder]]

	return div()
		:style(rail)
		:resize(
			{ edge = "right", min = theme:px(200), max = theme:px(360), grab = theme:px(5), onchange = handlerState.resize }
		):onMouseMove(handlerState.hover)
		:children(
			{
				ui.ripple(
					div():style(brandStyle):onClick(TOGGLE_SIDEBAR):children(brandChildren),
					"sidebar.brand",
					theme:color("text")
				),
				div():style(separator),
				div():style(navArea):children(navChildren),
				div():style(separator),
				div():style(spacer),
				div():style(head):children({ header }),
				div():style(listBox):children(rows)
			}
		)
end

--- The name a sidebar playlist hides until it is pointed at. It is drawn over the page rather
--- than inside the narrow sidebar, and clamped so the last row's label stays on screen.
---@class beat.components.chrome.SidebarTooltipProps
---@field width number # The window's width
---@field height number # The window's height
---@field ui beat.ui.Context

---@param app beat.App
---@param props beat.components.chrome.SidebarTooltipProps
---@return wonderland.Element?
function sidebar.tooltip(app, props)
	local width = props.width
	local hover = app.services.sidebar.hover
	if hover == nil or app.services.collections.taxonomy == nil then return nil end
	local playlist = app.services.collections.taxonomy:playlist(hover.id)
	if playlist == nil then return nil end

	local theme = app.services.appearance.theme
	local ctx = props.ui
	local pad = theme:px(8)
	local nameStyle = cache.of(ctx, tooltipMeasureStyle, "sidebarTooltipMeasure") --[[@as wonderland.StyleBuilder]]
	local measured = measure.width(app, playlist.name, nameStyle)
	local fallback = measure.estimate(playlist.name, theme:type("sm"), 0.45)
	local border = theme:px(1)
	local nameWidth = math.min(theme:px(180), math.max(theme:px(8), math.ceil(measured or fallback)))
	local boxWidth = nameWidth + pad * 2 + border * 2
	local arrowHeight = theme:px(7)
	local totalHeight = theme:px(30) + arrowHeight
	local artWidth = hover.height or theme:px(40)
	local centre = hover.x or (metrics.sidebarWidth(app, width) / 2)
	local wrapperX = centre - artWidth / 2
	local rowTop = hover.top or (hover.y - (hover.height or theme:px(52)) / 2)
	local wrapperY = math.max(theme:px(8), rowTop - totalHeight)

	-- The box is as wide as the run Wonderland measured, so emoji and other wide glyphs keep
	-- their own padding rather than being sized by a byte count.
	local box = cache.of(ctx, tooltipBoxStyle, "sidebarTooltipBox", boxWidth) --[[@as wonderland.StyleBuilder]]
	local nameTextStyle = cache.of(ctx, tooltipNameStyle, "sidebarTooltipName", nameWidth) --[[@as wonderland.StyleBuilder]]
	local arrowStyles = cache.of(ctx, tooltipArrowStyles, "sidebarTooltipArrow") --[[@as beat.components.chrome.SidebarArrowStyles]]
	local arrow = div():style(arrowStyles.style):canvas(arrowStyles.draw)
	local wrapperStyle = cache.of(
		ctx,
		tooltipWrapperStyle,
		"sidebarTooltipWrapper",
		wrapperX,
		wrapperY,
		artWidth,
		totalHeight
	)
	--[[@as wonderland.StyleBuilder]]

	return div()
		:style(wrapperStyle):onMouseMove(ignoreMouseMove)
		:children({ div():style(box):children({ text(playlist.name):style(nameTextStyle) }), arrow })
end

return sidebar
