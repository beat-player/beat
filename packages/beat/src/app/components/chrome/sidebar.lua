-- The rail down the left edge: where the app navigates from, the playlists played last, and the
-- name a row gives back while the pointer is on it.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local logo = require("beat.app.components.logo")
local format = require("beat.app.components.helpers.format")
local metrics = require("beat.app.components.helpers.metrics")
local measure = require("beat.app.components.helpers.measure")
local PlaylistArt = require("beat.app.components.playlist_art")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local sidebar = {}

---@class beat.components.chrome.SidebarProps
---@field width number # The window's width
---@field height number # The room the rail has
---@field ui beat.ui.Context

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
		{ kind = "home", icon = "home", label = "Home" },
		{ kind = "library", icon = "library", label = "Library" },
		{ kind = "playlists", icon = "playlists", label = "Playlists" }
	}

	-- A plugin's destinations come after the app's own, in the order they asked for.
	for _, entry in ipairs(app.registry:nav()) do
		nav[#nav + 1] = { page = entry.page, icon = entry.icon, label = entry.title }
	end

	local navRowHeight = (theme:px(collapsed ? 44 : 42))
	local navHeight = navRowHeight * #nav + math.max(0, #nav - 1) * theme:px(2) + theme:px(20)
	local navChildren = {}
	for _, item in ipairs(nav) do
		local route = (item.page or { kind = item.kind }) --[[@as { kind: string, id: number? }]]
		local active = current.kind == route.kind and (route.id == nil or current.id == route.id)
		local fg = active ? (theme:color("text")) : (theme:color("muted"))

		local rowChildren = {
			ui.icon(ctx, { name = item.icon, size = theme:px(19), colour = active ? (theme:color("accent")) : fg })
		}
		if not collapsed then
			rowChildren[#rowChildren + 1] =
				text(item.label):style(theme:s():text(theme:type("base")):weight("semibold"):fg(fg))
		end

		navChildren[#navChildren + 1] = ui.listRow(
			ctx,
			{
				height = navRowHeight,
				gap = theme:px(12),
				padding = theme:px(10),
				justify = collapsed and "center" or nil,
				active = active,
				onClick = { type = "navigate", page = route },
				children = rowChildren
			}
		)
	end

	local brandChildren = { logo.view(app, { size = theme:px(22), colour = theme:color("accent") }) }
	if not collapsed then
		brandChildren[#brandChildren + 1] = text("beat")
			:style(theme:s():text(theme:type("xl")):weight("bold"):fg(theme:color("text")))
	end
	local brandStyle = sty():row():wrel(1.0):h(theme:px(52)):gap(theme:px(10)):align("center")
	if collapsed then brandStyle:justify("center") end

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

	for _, playlist in ipairs(playlists) do
		local tracks = PlaylistArt.tracks(app, playlist)
		local active = current.kind == "playlist" and current.id == playlist.id
		local rowChildren = {
			PlaylistArt.view(app, { tracks = tracks, size = artSize, name = playlist.name, ui = ctx })
		}
		if not collapsed then
			rowChildren[#rowChildren + 1] =
				text(format.count(#tracks, "track")):style(theme:s():text(theme:type("xs")):fg(theme:color("faint")))
		end

		-- A row that is not being pointed at says nothing; the tooltip is where a playlist gets
		-- its name back. The list's own hit test is what knows which row the pointer is over.
		rows[#rows + 1] = ui.listRow(
			ctx,
			{
				height = rowHeight,
				gap = theme:px(10),
				padding = 0,
				justify = collapsed and "center" or "space-between",
				active = active,
				onClick = { type = "navigate", page = { kind = "playlist", id = playlist.id } },
				children = rowChildren
			}
		)
	end

	local createStyle = sty()
		:row():wrel(1.0):h(rowHeight):gap(theme:px(10)):align("center"):radius(theme:radius("sm"))
		:bg(theme:color("accent", 0.13))
	local createHover = sty()
		:row():wrel(1.0):h(rowHeight):gap(theme:px(10)):align("center"):radius(theme:radius("sm"))
		:bg(theme:color("accent", 0.22))
	if collapsed then
		createStyle:justify("center")
		createHover:justify("center")
	else
		createStyle:pad(0, theme:px(8), 0, theme:px(8))
		createHover:pad(0, theme:px(8), 0, theme:px(8))
	end

	local create = div()
		:style(createStyle):hover(createHover):onClick({ type = "open", overlay = "playlist_dialog", smart = false })
		:children(
			{
				div()
					:style(
						sty()
							:size(artSize, artSize):radius(theme:radius("sm")):bg(theme:color("accent", 0.18)):align("center")
							:justify("center")
					):children(ui.icon(ctx, { name = "add", size = theme:px(18), colour = theme:color("accent") }))
			}
		)
	if not collapsed then
		create:children(
			text("New playlist"):style(theme:s():text(theme:type("sm")):weight("semibold"):fg(theme:color("accent")))
		)
	end
	rows[#rows + 1] = create

	local listHeight = #rows * rowHeight + math.max(0, #rows - 1) * rowGap

	---@param relY number
	---@return { type: string, id: number?, y: number? }?
	local function hoverAt(relY)
		local offset = relY - listTop
		local hovered = nil
		if offset >= 0 then
			local index = math.floor(offset / rowStep) + 1
			local within = offset - (index - 1) * rowStep
			if index <= #playlists and within < rowHeight then
				local rowTop = listTop + (index - 1) * rowStep
				local artX = collapsed and side / 2 or (theme:px(16) + artSize / 2)
				hovered = {
					id = playlists[index].id,
					y = rowTop + rowHeight / 2,
					-- The arrow meets the artwork's top edge, not the taller hover row around it.
					top = rowTop + (rowHeight - artSize) / 2,
					x = artX,
					height = artSize
				}
			end
		end

		-- A message is a frame: moving inside one row, or over anything that has no shortcut,
		-- asks for nothing when the tooltip is already in the state that movement means.
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

	return div():style(sty():w(side):hrel(1.0):column():pad(0, theme:px(16), 0, theme:px(16)):gap(theme:px(4)):bg(theme:color("sidebar"))):resize({ edge = "right", min = theme:px(200), max = theme:px(360), grab = theme:px(5), onchange = |size| -> { type = "sidebarWidth", width = size / theme.scale } }):onMouseMove(|_, relY| -> hoverAt(tonumber(relY) or 0)):children({ div():style(brandStyle):onClick({ type = "toggleSidebar" }):children(brandChildren), div():style(sty():h(1):bg(theme:color("border"))), div():style(sty():column():h(navHeight):gap(theme:px(2)):pad(theme:px(10), 0, 0, 0)):children(navChildren), div():style(sty():h(1):bg(theme:color("border"))), div():style(sty():h(theme:px(16))), div():style(sty():column():h((theme:px(collapsed ? 0 : 28)) + listHeight):gap(sectionGap)):children({ (function()
		if collapsed then return div():style(sty():h(theme:px(0))) end
		return div():style(sty():row():wrel(1.0):h(theme:px(24)):align("center"):justify("space-between")):children({ text("Playlists"):style(theme:s():text(theme:type("xs")):weight("bold"):fg(theme:color("text"))) })
	end)(), div():style(sty():column():h(listHeight):gap(rowGap)):children(rows) }) })
end

--- The name a sidebar playlist hides until it is pointed at. It is drawn over the page rather
--- than inside the narrow sidebar, and clamped so the last row's label stays on screen.
---@class beat.components.chrome.SidebarTooltipProps
---@field width number # The window's width
---@field height number # The window's height

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
	local pad = theme:px(8)
	local nameStyle = theme:s():text(theme:type("sm")):weight("semibold")
	local measured = measure.width(app, playlist.name, nameStyle)
	local fallback = measure.estimate(playlist.name, theme:type("sm"), 0.45)
	local border = theme:px(1)
	local nameWidth = math.min(theme:px(180), math.max(theme:px(8), math.ceil(measured or fallback)))
	local boxWidth = nameWidth + pad * 2 + border * 2
	local boxHeight = theme:px(30)
	local arrowWidth = theme:px(14)
	local arrowHeight = theme:px(7)
	local totalHeight = boxHeight + arrowHeight
	local artWidth = hover.height or theme:px(40)
	local centre = hover.x or (metrics.sidebarWidth(app, width) / 2)
	local wrapperX = centre - artWidth / 2
	local rowTop = hover.top or (hover.y - (hover.height or theme:px(52)) / 2)
	local wrapperY = math.max(theme:px(8), rowTop - totalHeight)

	-- The box is as wide as the run Wonderland measured, so emoji and other wide glyphs keep
	-- their own padding rather than being sized by a byte count.
	local box = div()
		:style(
			sty()
				:w(boxWidth):h(boxHeight):row():align("center"):pad(0, pad, 0, pad):radius(theme:radius("sm"))
				:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
				:shadow(0, theme:px(4), theme:px(14), "#00000099")
		)
		:children(
			{
				text(playlist.name):style(theme:s():w(nameWidth):text(theme:type("sm")):weight("semibold"):fg(theme:color("text")))
			}
		)

	local arrow = div():style(sty():w(arrowWidth):h(arrowHeight)):canvas(function(canvas)
		canvas:polygon({ 0, 0, canvas.width, 0, canvas.width / 2, canvas.height }, theme:color("elevated"))
	end)

	return div()
		:style(sty():w(artWidth):h(totalHeight):offset(wrapperX, wrapperY):z(80):column():align("center"))
		:onMouseMove(|| -> nil):children({ box, arrow })
end

return sidebar
