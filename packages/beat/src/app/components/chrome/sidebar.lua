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

---@class beat.components.chrome.SidebarCreateStyles
---@field base wonderland.StyleBuilder
---@field hover wonderland.StyleBuilder
---@field iconBox wonderland.StyleBuilder
---@field label wonderland.StyleBuilder

---@class beat.components.chrome.SidebarHeaderStyles
---@field row wonderland.StyleBuilder
---@field text wonderland.StyleBuilder

-- What the rail's boxes are built from: the theme and a handful of numbers. Each is a module-level
-- function so a frame asks the cache for the record it needs and builds nothing.
---@param ctx beat.ui.Context
---@param fg string
---@return wonderland.StyleBuilder
local function navLabelStyle(ctx, fg)
	return ctx:s():text(ctx:type("base")):weight("semibold"):fg(fg)
end

---@param ctx beat.ui.Context
---@return wonderland.StyleBuilder
local function brandTextStyle(ctx)
	return ctx:s():text(ctx:type("xl")):weight("bold"):fg(ctx:color("text"))
end

---@param ctx beat.ui.Context
---@param collapsed boolean
---@return wonderland.StyleBuilder
local function brandBoxStyle(ctx, collapsed)
	local style = sty():row():wrel(1.0):h(ctx:px(52)):gap(ctx:px(10)):align("center")
	if collapsed then style:justify("center") end
	return style
end

---@param ctx beat.ui.Context
---@return wonderland.StyleBuilder
local function countTextStyle(ctx)
	return ctx:s():text(ctx:type("xs")):fg(ctx:color("faint"))
end

---@param ctx beat.ui.Context
---@param rowHeight number
---@param artSize number
---@param collapsed boolean
---@return beat.components.chrome.SidebarCreateStyles
local function createStyles(ctx, rowHeight, artSize, collapsed)
	local radius = ctx:radius("sm")
	local base = sty()
		:row():wrel(1.0):h(rowHeight):gap(ctx:px(10)):align("center"):radius(radius):bg(ctx:color("accent", 0.13))
	local hover = sty()
		:row():wrel(1.0):h(rowHeight):gap(ctx:px(10)):align("center"):radius(radius):bg(ctx:color("accent", 0.22))
	if collapsed then
		base:justify("center")
		hover:justify("center")
	else
		base:pad(0, ctx:px(8), 0, ctx:px(8))
		hover:pad(0, ctx:px(8), 0, ctx:px(8))
	end
	return {
		base = base,
		hover = hover,
		iconBox = sty():size(artSize, artSize):radius(radius):bg(ctx:color("accent", 0.18)):align("center"):justify("center"),
		label = ctx:s():text(ctx:type("sm")):weight("semibold"):fg(ctx:color("accent"))
	}
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
---@param collapsed boolean
---@return wonderland.StyleBuilder
local function headBoxStyle(ctx, collapsed)
	return sty():column():h(((ctx:px(collapsed ? 0 : 28))))
end

---@param ctx beat.ui.Context
---@return beat.components.chrome.SidebarHeaderStyles
local function headerStyles(ctx)
	return {
		row = sty():row():wrel(1.0):h(ctx:px(24)):align("center"):justify("space-between"),
		text = ctx:s():text(ctx:type("xs")):weight("bold"):fg(ctx:color("text"))
	}
end

---@param ctx beat.ui.Context
---@return wonderland.StyleBuilder
local function zeroStyle(ctx)
	return sty():h(ctx:px(0))
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

---@class beat.components.chrome.SidebarProps
---@field width number # The window's width
---@field height number # The room the rail has
---@field ui beat.ui.Context

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

---@param app beat.App
---@param props beat.components.chrome.SidebarProps
---@return wonderland.Element
function sidebar.view(app, props)
	local width, height = props.width, props.height
	local ctx = props.ui
	local theme = app.services.appearance.theme
	local collapsed = app.services.settings.values.sidebarCollapsed or width < 1040
	local side = metrics.sidebarWidth(app, width)
	local current = app.page

	local nav = {
		{ kind = "home", icon = "home", label = "Home", route = ROUTE_HOME, message = GO_HOME },
		{ kind = "library", icon = "library", label = "Library", route = ROUTE_LIBRARY, message = GO_LIBRARY },
		{ kind = "playlists", icon = "playlists", label = "Playlists", route = ROUTE_PLAYLISTS, message = GO_PLAYLISTS }
	}

	-- A plugin's destinations come after the app's own, in the order they asked for.
	for _, entry in ipairs(app.registry:nav()) do
		nav[#nav + 1] = { page = entry.page, icon = entry.icon, label = entry.title, message = navMessage(entry) }
	end

	local navRowHeight = (theme:px(collapsed ? 44 : 42))
	local navHeight = navRowHeight * #nav + math.max(0, #nav - 1) * theme:px(2) + theme:px(20)
	local navChildren = {}
	for _, item in ipairs(nav) do
		local route = (item.route or item.page) --[[@as { kind: string, id: number? }]]
		local active = current.kind == route.kind and (route.id == nil or current.id == route.id)
		local fg = active ? (theme:color("text")) : (theme:color("muted"))

		local rowChildren = {
			ui.icon(ctx, { name = item.icon, size = theme:px(19), colour = active ? (theme:color("accent")) : fg })
		}
		if not collapsed then
			local labelStyle = cache.of(ctx, navLabelStyle, "sidebarNavLabel", fg) --[[@as wonderland.StyleBuilder]]
			rowChildren[#rowChildren + 1] = text(item.label):style(labelStyle)
		end

		navChildren[#navChildren + 1] = ui.listRow(ctx, {
			height = navRowHeight,
			gap = theme:px(12),
			padding = theme:px(10),
			justify = collapsed and "center" or nil,
			active = active,
			onClick = item.message,
			children = rowChildren
		})
	end

	local brandChildren = { logo.view(app, { size = theme:px(22), colour = theme:color("accent") }) }
	if not collapsed then
		local brandText = cache.of(ctx, brandTextStyle, "sidebarBrandText") --[[@as wonderland.StyleBuilder]]
		brandChildren[#brandChildren + 1] = text("beat"):style(brandText)
	end
	local brandStyle = cache.of(ctx, brandBoxStyle, "sidebarBrand", collapsed) --[[@as wonderland.StyleBuilder]]

	local rowGap = theme:px(3)
	local sectionGap = theme:px(4)
	local playlists = app.services.collections:recentPlaylists(3)
	local rowCount = #playlists + 1
	local headerHeight = collapsed ? (theme:px(0)) : (theme:px(24))
	-- The sidebar gaps and the header are style values, so the hover hit test can be the rows'
	-- own geometry without asking the layout that has not run yet.
	local sectionTop = theme:px(52) + theme:px(1) + theme:px(16) + theme:px(1) + navHeight + theme:px(4) * 5
	local sectionInset = collapsed and sectionGap or headerHeight + sectionGap
	local available = height - sectionTop - sectionInset
	local baseRowHeight = (theme:px(collapsed ? 44 : 52))
	local rowHeight = math.min(
		baseRowHeight,
		math.max(theme:px(36), math.floor((available - (rowCount - 1) * rowGap) / rowCount))
	)
	local artSize = math.min(((theme:px(collapsed ? 36 : 40))), rowHeight - (theme:px(8)))
	local rowStep = rowHeight + rowGap
	local listTop = sectionTop + sectionInset
	local rows = {}

	local countStyle = cache.of(ctx, countTextStyle, "sidebarCount") --[[@as wonderland.StyleBuilder]]

	for _, playlist in ipairs(playlists) do
		local tracks = PlaylistArt.tracks(app, playlist)
		local active = current.kind == "playlist" and current.id == playlist.id
		local rowChildren = { PlaylistArt.view(app, { tracks = tracks, size = artSize, name = playlist.name, ui = ctx }) }
		if not collapsed then
			rowChildren[#rowChildren + 1] = text(format.count(#tracks, "track")):style(countStyle)
		end

		-- A row that is not being pointed at says nothing; the tooltip is where a playlist gets
		-- its name back. The list's own hit test is what knows which row the pointer is over.
		rows[#rows + 1] = ui.listRow(ctx, {
			height = rowHeight,
			gap = theme:px(10),
			padding = 0,
			justify = collapsed and "center" or "space-between",
			active = active,
			onClick = playlistMessage(playlist),
			children = rowChildren
		})
	end

	-- The create row's geometry is the playlist rows' height and artwork, so the two read as one
	-- list: one record of builders per size the rail comes to.
	local createSet = cache.of(ctx, createStyles, "sidebarCreate", rowHeight, artSize, collapsed) --[[@as beat.components.chrome.SidebarCreateStyles]]

	local createChildren = {
		div():style(createSet.iconBox):children(ui.icon(ctx, {
			name = "add",
			size = theme:px(18),
			colour = theme:color("accent")
		}))
	}
	if not collapsed then createChildren[#createChildren + 1] = text("New playlist"):style(createSet.label) end
	local create = div():style(createSet.base):hover(createSet.hover):onClick(NEW_PLAYLIST):children(createChildren)
	rows[#rows + 1] = create

	local listHeight = #rows * rowHeight + math.max(0, #rows - 1) * rowGap

	local handlerState = handlersOf(app)
	handlerState.listTop, handlerState.rowStep, handlerState.rowHeight = listTop, rowStep, rowHeight
	handlerState.playlists, handlerState.artSize = playlists, artSize
	handlerState.artX = collapsed and side / 2 or (theme:px(16) + artSize / 2)

	-- The rail and the dividers are one size per theme: the width the rail is the only thing that
	-- changes with the window.
	local rail = cache.of(ctx, railStyle, "sidebarRoot", side) --[[@as wonderland.StyleBuilder]]
	local separator = cache.of(ctx, separatorStyle, "sidebarSeparator") --[[@as wonderland.StyleBuilder]]
	local navArea = cache.of(ctx, navAreaStyle, "sidebarNavArea", navHeight) --[[@as wonderland.StyleBuilder]]
	local spacer = cache.of(ctx, spacerStyle, "sidebarSpacer") --[[@as wonderland.StyleBuilder]]
	local head = cache.of(ctx, headBoxStyle, "sidebarHead", collapsed) --[[@as wonderland.StyleBuilder]]
	local headers = cache.of(ctx, headerStyles, "sidebarHeader") --[[@as beat.components.chrome.SidebarHeaderStyles]]
	local header
	if collapsed then
		local zero = cache.of(ctx, zeroStyle, "sidebarZero") --[[@as wonderland.StyleBuilder]]
		header = div():style(zero)
	else
		header = div():style(headers.row):children({ text("Playlists"):style(headers.text) })
	end
	local listBox = cache.of(ctx, listBoxStyle, "sidebarList", listHeight, rowGap) --[[@as wonderland.StyleBuilder]]

	return div():style(rail):resize({
		edge = "right",
		min = theme:px(200),
		max = theme:px(360),
		grab = theme:px(5),
		onchange = handlerState.resize
	}):onMouseMove(handlerState.hover):children({
		div():style(brandStyle):onClick(TOGGLE_SIDEBAR):children(brandChildren),
		div():style(separator),
		div():style(navArea):children(navChildren),
		div():style(separator),
		div():style(spacer),
		div():style(head):children({ header }),
		div():style(listBox):children(rows)
	})
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

	return div():style(wrapperStyle):onMouseMove(ignoreMouseMove):children({
		div():style(box):children({ text(playlist.name):style(nameTextStyle) }),
		arrow
	})
end

return sidebar
