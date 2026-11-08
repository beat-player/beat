-- The album shelf: every album in the library, as cards or as rows, windowed as it scrolls.
local wonderland = require("wonderland")
local format = require("beat.app.components.helpers.format")
local albumCard = require("beat.app.components.album_card")
local button = require("beat.app.components.button")
local iconButton = require("beat.app.components.icon_button")
local cover = require("beat.app.components.cover")
local emptyState = require("beat.app.components.empty_state")
local metrics = require("beat.app.components.helpers.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@type beat.PageSurface
local libraryPage = {}

local SORT_LABELS = {
	title = "Title",
	artist = "Artist",
	year = "Year",
	recent = "Recently added",
	modified = "File modified",
}

--- The view the shelf would switch to, drawn rather than taken from the icon face: the face has
--- no grid, and a list from it next to a drawn grid would not match it in weight.
---@param app beat.App
---@param size number
---@param grid boolean # Four tiles; otherwise three rows
---@return wonderland.Element
local function viewButton(app, size, grid)
	local theme = app.services.appearance.theme
	local colour = theme:color("muted")
	local inner = math.max(12, math.floor(size * 0.5 + 0.5))

	return iconButton.surface(app, {
		size = size,
		onClick = { type = "toggleView"},
		content = div():style(sty():size(inner, inner)):canvas(function(canvas)
			local gap = math.max(2, math.floor(inner * 0.16))
			if grid then
				local tile = math.floor((canvas.width - gap) / 2)
				for at = 0, 3 do
					canvas:rect((at % 2) * (tile + gap), math.floor(at / 2) * (tile + gap), tile, tile,
					colour, math.max(1, math.floor(tile * 0.25)))
				end
			else
				local line = math.max(2, math.floor(inner * 0.14))
				local step = math.floor((canvas.height - line) / 2)
				for at = 0, 2 do
					local y = at * step
					canvas:rect(0, y, line, line, colour, line / 2)
					canvas:rect(line + gap, y, canvas.width - line - gap, line, colour, line / 2)
				end
			end
		end),
	})
end

function libraryPage.update(app, page, message)
	if message.type == "toggleView" then
		app.services.settings.values.view = app.services.settings.values.view == "list" and "grid" or "list"
		app.services.settings:changed()
		return true
	end
	return false
end

function libraryPage.view(app, page, window)
	local theme = app.services.appearance.theme
	local library = app.services.library.current
	if library == nil then
		return emptyState.view(app, {
		title = "Awkward. Nothing's here.",
		actionLabel = "Choose a folder",
		action = { type = "chooseFolder"},
		icon = "😬",
		})
	end
	local content = metrics.contentWidth(app, window.width)
	local albums = app.services.library:sorted(app.services.settings.values.sort)
	local mobile = metrics.mobile(app, window.width)

	local list = app.services.settings.values.view == "list"
	local columns
	if content >= 900 then
		columns = 5
	elseif content >= 640 then
		columns = 4
	elseif content >= 420 then
		columns = 3
	elseif content >= 260 then
		columns = 2
	else
		columns = 1
	end
	local gap = theme:space(16)
	local cardWidth = math.max(120, math.floor((content - gap * (columns - 1)) / columns))

	-- Below this the title and the controls cannot sit on one line without one covering the
	-- other, so the controls move under the title and the header grows by a row.
	local stacked = content < 480
	local headerHeight = stacked and theme:px(104) or theme:px(58)
	local viewWidth = theme:px(32)
	local sortWidth = math.max(theme:px(88),
	math.min(theme:px(150), content - viewWidth - theme:px(8)))
	local titleWidth = math.max(theme:px(0), content - sortWidth - viewWidth - theme:space(16))

	local titleBlock = div():style(sty():column():w(stacked and content or titleWidth)
	:h(stacked and theme:px(58) or headerHeight):gap(4)):children({
	text("Your library"):style(theme:s():wrel(1.0):text(theme:type("xxl")):weight("bold")
	:fg(theme:color("text")):ellipsis()),
	text(format.count(#albums, "album") .. " · " .. format.count(#library.tracks, "track")):style(
	theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()
	),
	})

	local sort = app.services.settings.values.sort
	local controls = div():style(sty():row():h(theme:px(32)):gap(theme:px(8)):align("center")
	:justify(stacked and "start" or "end")):children({
	button.view(app, {
	label = sortWidth < theme:px(130) and "Sort" or ("Sort: " .. (SORT_LABELS[sort] or sort)),
	onClick = { type = "open", overlay = "sort_menu"},
	height = theme:px(32),
	width = sortWidth,
	}),
	viewButton(app, viewWidth, list),
	})

	local header = div()
	:style(stacked
	and sty():column():wrel(1.0):h(headerHeight):gap(theme:px(10))
	or sty():row():wrel(1.0):h(headerHeight):align("center"):justify("space-between"))
	:children({
	titleBlock,
	controls,
	})

	if #albums == 0 then
		return emptyState.view(app, {
		title = "Awkward. Nothing's here.",
		actionLabel = "Choose a folder",
		action = { type = "chooseFolder"},
		icon = "😬",
		})
	end

	local cardHeight = albumCard.height(app, { width = cardWidth })
	local rowHeight = list and theme:px(64) or (cardHeight + theme:space(12))
	local totalRows = list and #albums or math.ceil(#albums / columns)
	local contentHeight = headerHeight + theme:space(18) + totalRows * rowHeight
	local viewport = metrics.viewportHeight(app, window.width, window.height)
	app.services.scroll:setLimit(app:pageKey(),
	math.max(0, contentHeight - viewport))
	local scroll = app.services.scroll:offset(app:pageKey())
	local listStart = headerHeight + theme:space(18)
	local first, last, top = app.services.scroll.slices(#albums, list and 1 or columns, rowHeight,
	math.max(0, scroll - listStart), viewport)
	---@cast first number
	---@cast last number
	---@cast top number
	local children = {}

	if top > 0 then children[#children + 1] = div():style(sty():h(top)) end

	if list then
		for at = first, last do
				local album = albums[at]
				children[#children + 1] = div()
				:style(sty():row():w(content):h(rowHeight):gap(theme:px(14)):align("center")
				:radius(theme:radius("sm")))
				:hover(sty():row():w(content):h(rowHeight):gap(theme:px(14)):align("center")
				:radius(theme:radius("sm")):bg(theme:color("hover")))
				:onClick({ type = "navigate", page = { kind = "album", id = album.id}})
				:onContextMenu(function(_, _, _, _, _, windowX, windowY)
					return { type = "open", overlay = "menu", menu = "album", id = album.id, x = windowX, y = windowY}
				end)
				:children({
				cover.view(app, { album = album, size = theme:px(48), radius = theme:radius("sm") }),
				div():style(sty():column():w(content - theme:px(mobile and 80 or 190))):children({
				text(album.title):style(theme:s():wrel(1.0):text(theme:type("base"))
				:weight("semibold"):fg(theme:color("text")):ellipsis()),
				text(album.artist .. (album.year and (" · " .. album.year) or "")):style(
				theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()),
				}),
				(not mobile) and text(format.count(#album.tracks, "track")):style(
				theme:s():text(theme:type("sm")):fg(theme:color("muted"))) or div():style(
				sty():w(0):h(0)),
				(not mobile) and text(format.duration(album.duration)):style(
				theme:s():text(theme:type("sm")):fg(theme:color("faint"))) or div():style(
				sty():w(0):h(0)),
				})
			end
	else
		local row = {}
		for at = first, last do
				local album = albums[at]
				row[#row + 1] = albumCard.view(app, {
				album = album,
				width = cardWidth,
				onOpen = { type = "navigate", page = { kind = "album", id = album.id}},
				onPlay = { type = "playAlbum", id = album.id},
				})
				if #row == columns or at == last then
					children[#children + 1] = div():style(sty():row():wrel(1.0):h(rowHeight):gap(gap)):children(row)
					row = {}
				end
			end
	end

	local usedRows = last - first + 1
	local bottomPad = math.max(0, (totalRows - (first - 1) - usedRows) * rowHeight)
	if bottomPad > 0 then children[#children + 1] = div():style(sty():h(bottomPad)) end

	return div():style(sty():column():wrel(1.0):h(contentHeight):gap(theme:space(18))):children({
	header,
	div():style(sty():column():wrel(1.0):h(totalRows * rowHeight):gap(0)):children(children),
	})
end

return libraryPage
