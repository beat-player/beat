-- The album shelf: every album in the library, as cards or as rows, windowed as it scrolls.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local format = require("beat.app.components.helpers.format")
local albumCard = require("beat.app.components.album_card")
local cover = require("beat.app.components.cover")
local metrics = require("beat.app.components.helpers.metrics")
local styles = require("beat.app.components.helpers.styles")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.LibraryRowStyles
---@field row wonderland.StyleBuilder
---@field rowHover wonderland.StyleBuilder
---@field coverSize number
---@field coverRadius number
---@field names wonderland.StyleBuilder
---@field title wonderland.StyleBuilder
---@field artist wonderland.StyleBuilder
---@field count wonderland.StyleBuilder
---@field duration wonderland.StyleBuilder
---@field none wonderland.StyleBuilder

--- The mark a view toggle draws, and the style of the box it is drawn in: one per theme and view.
---@class beat.LibraryViewMark
---@field inner number
---@field colour string
---@field mark wonderland.StyleBuilder
---@field paint fun(canvas: wonderland.Canvas)

--- The header's boxes at one width, kept per stack and width.
---@class beat.LibraryHeaderStyles
---@field titleWidth number
---@field headerHeight number
---@field titleBlock wonderland.StyleBuilder
---@field controls wonderland.StyleBuilder
---@field header wonderland.StyleBuilder

--- The header's text styles, which depend on the theme alone.
---@class beat.LibraryTextStyles
---@field title wonderland.StyleBuilder?
---@field summary wonderland.StyleBuilder?

--- The header's second line, kept with the counts it names.
---@class beat.LibrarySummary
---@field albums number?
---@field tracks number?
---@field text string

--- The sort button's word, kept with the order and the room it has to say it in.
---@class beat.LibrarySortLabel
---@field sort string?
---@field narrow boolean?
---@field text string

--- The boxes around the drawn rows, kept with the slice and content height they were made for.
---@class beat.LibraryFrameStyles
---@field top number?
---@field firstPad wonderland.StyleBuilder
---@field rowHeight number?
---@field gap number?
---@field gridRow wonderland.StyleBuilder
---@field bottomPadHeight number?
---@field bottomPad wonderland.StyleBuilder
---@field columnHeight number?
---@field column wonderland.StyleBuilder
---@field contentHeight number?
---@field content wonderland.StyleBuilder

---@type beat.PageSurface
local libraryPage = {}

local SORT_LABELS = {
	title = "Title",
	artist = "Artist",
	year = "Year",
	recent = "Recently added",
	modified = "File modified"
}

-- The messages the header's controls send, made once rather than once per frame.
local TOGGLE_VIEW = { type = "toggleView" }
local OPEN_SORT = { type = "open", overlay = "sort_menu" }

--- The view the shelf would switch to, drawn rather than taken from the icon face: the face has
--- no grid, and a list from it next to a drawn grid would not match it in weight.
---@param app beat.App
---@param ctx beat.ui.Context
---@param size number
---@param grid boolean # Four tiles; otherwise three rows
local function viewButton(app, ctx, size, grid)
	local theme = app.services.appearance.theme
	local colour = theme:color("muted")
	local inner = math.max(12, math.floor(size * 0.5 + 0.5))

	-- The mark is a style and the function that draws it, both the same for every frame of a
	-- theme at this size: kept rather than made again on every scroll step.
	local kept = styles.of(theme, "libraryViewMark", grid and 1 or 0) --[[@as beat.LibraryViewMark]]
	if kept.inner ~= inner or kept.colour ~= colour then
		local mark = sty():size(inner, inner)
		local gap = math.max(2, math.floor(inner * 0.16))
		kept.inner, kept.colour, kept.mark = inner, colour, mark
		kept.paint = function(canvas)
			if grid then
				local tile = math.floor((canvas.width - gap) / 2)
				for at = 0, 3 do
					canvas:rect((at % 2) * (tile + gap), math.floor(at / 2) * (tile + gap), tile, tile, colour, math.max(1, math.floor(tile * 0.25)))
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
		end
	end

	return ui.iconButton(ctx, { size = size, onClick = TOGGLE_VIEW, content = div():style(kept.mark):canvas(kept.paint) })
end

---@param app beat.App
---@param page beat.PageInstance
---@param message beat.Message
function libraryPage.update(app, page, message)
	if message.type == "toggleView" then
		app.services.settings.values.view = app.services.settings.values.view == "list" ? "grid" : "list"
		app.services.settings:changed()
		return true
	end
	return false
end

---@param app beat.App
---@param page beat.PageInstance
---@param window wonderland.RenderWindow
function libraryPage.view(app, page, window)
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local library = app.services.library.current
	if library == nil then
		return ui.emptyState(
			ctx,
			{
				title = "Awkward. Nothing's here.",
				actionLabel = "Choose a folder",
				action = { type = "chooseFolder" },
				icon = "😬"
			}
		)
	end
	local content = metrics.contentWidth(app, window.width)
	local albums = app.services.library:sorted(app.services.settings.values.sort)
	local mobile = metrics.mobile(app, window.width)

	local list = app.services.settings.values.view == "list"
	local columns = metrics.gridColumns(app, content)
	local gap = theme:space(16)
	local cardWidth = math.max(120, math.floor((content - gap * (columns - 1)) / columns))

	-- Below this the title and the controls cannot sit on one line without one covering the
	-- other, so the controls move under the title and the header grows by a row.
	local stacked = metrics.units(app, content) < 480
	local headerHeight = stacked ? (theme:px(104)) : (theme:px(58))
	local viewWidth = theme:px(32)
	local sortWidth = math.max(theme:px(88), math.min(theme:px(150), content - viewWidth - theme:px(8)))
	local titleWidth = math.max(theme:px(0), content - sortWidth - viewWidth - theme:space(16))

	-- The header is the same for every frame of a theme at this width, and a scroll step builds the
	-- page again: its boxes and text styles are kept where the theme keeps what it built, and made
	-- only when the width or the name of things has changed.
	local chrome = styles.of(theme, "libraryHeader") --[[@as table<number, beat.LibraryHeaderStyles?>]]
	local textStyles = styles.of(theme, "libraryText") --[[@as beat.LibraryTextStyles]]
	local titleStyle = textStyles.title --[[@as wonderland.StyleBuilder]]
	if titleStyle == nil then
		titleStyle = theme:s():wrel(1.0):text(theme:type("xxl")):weight("bold"):fg(theme:color("text")):ellipsis()
		textStyles.title = titleStyle
	end
	local summaryStyle = textStyles.summary --[[@as wonderland.StyleBuilder]]
	if summaryStyle == nil then
		summaryStyle = theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()
		textStyles.summary = summaryStyle
	end
	local summary = styles.of(theme, "librarySummary") --[[@as beat.LibrarySummary]]
	if summary.albums ~= #albums or summary.tracks ~= #library.tracks then
		summary.albums, summary.tracks = #albums, #library.tracks
		summary.text = format.count(#albums, "album") .. ", " .. format.count(#library.tracks, "track")
	end

	local blockWidth = stacked and content or titleWidth
	local kept = chrome[stacked and 1 or 2]
	if kept == nil or kept.titleWidth ~= blockWidth or kept.headerHeight ~= headerHeight then
		kept = {
			titleWidth = blockWidth,
			headerHeight = headerHeight,
			titleBlock = sty():column():w(blockWidth):h(stacked and theme:px(58) or headerHeight):gap(4),
			controls = sty():row():h(theme:px(32)):gap(theme:px(8)):align("center"):justify(stacked and "start" or "end"),
			header = stacked and (sty():column():wrel(1.0):h(headerHeight):gap(theme:px(10)))
				or (sty():row():wrel(1.0):h(headerHeight):align("center"):justify("space-between"))
		}
		chrome[stacked and 1 or 2] = kept
	end

	local sort = app.services.settings.values.sort
	local narrow = sortWidth < theme:px(130)
	local label = styles.of(theme, "librarySortLabel") --[[@as beat.LibrarySortLabel]]
	if label.sort ~= sort or label.narrow ~= narrow then
		label.sort, label.narrow = sort, narrow
		label.text = narrow and "Sort" or ("Sort: " .. (SORT_LABELS[sort] or sort))
	end

	local titleBlock = div():style(kept.titleBlock):children(
		text("Library"):style(titleStyle),
		text(summary.text):style(summaryStyle)
	)

	local controls = div():style(kept.controls):children(
		ui.button(
			ctx,
			{
				label = label.text,
				onClick = OPEN_SORT,
				height = theme:px(32),
				width = sortWidth
			}
		),
		viewButton(app, ctx, viewWidth, list)
	)

	local header = div():style(kept.header):children(titleBlock, controls)

	if #albums == 0 then
		return ui.emptyState(
			ctx,
			{
				title = "Awkward. Nothing's here.",
				actionLabel = "Choose a folder",
				action = { type = "chooseFolder" },
				icon = "😬"
			}
		)
	end

	local cardHeight = albumCard.height(app, { width = cardWidth })
	local rowHeight = list ? (theme:px(64)) : cardHeight + (theme:space(12))
	local totalRows = list and #albums or math.ceil(#albums / columns)
	local contentHeight = headerHeight + theme:space(18) + totalRows * rowHeight
	local viewport = metrics.viewportHeight(app, window.width, window.height)
	app.services.scroll:setLimit(app:pageKey(), metrics.pageScrollLimit(app, window, contentHeight))
	local scroll = app.services.scroll:offset(app:pageKey())
	local listStart = headerHeight + theme:space(18)
	local first, last, top = app.services.scroll.slices(
		#albums,
		list ? 1 : columns,
		rowHeight,
		math.max(0, scroll - listStart),
		viewport
	)
	local children = {}

	-- The padding above and below the drawn rows and the boxes around them depend on the slice and
	-- the content, which are the same for a run of scroll frames: kept rather than made again.
	local frameStyles = styles.of(theme, "libraryFrame") --[[@as beat.LibraryFrameStyles]]
	if top > 0 then
		if frameStyles.top ~= top then
			frameStyles.top = top
			frameStyles.firstPad = sty():h(top)
		end
		children[#children + 1] = div():style(frameStyles.firstPad)
	end

	if list then
		local s = styles.of(theme, mobile and "libraryRowsMobile" or "libraryRows", content) --[[@as beat.LibraryRowStyles]]
		if s.row == nil then
			local function row()
				return sty():row():w(content):h(rowHeight):gap(theme:px(14)):align("center"):radius(theme:radius("sm"))
			end
			s.row = row()
			s.rowHover = row():bg(theme:color("hover"))
			s.coverSize = theme:px(48)
			s.coverRadius = theme:radius("sm")
			-- As tall as the cover and laid from its top, so the title starts level with the
			-- picture's top edge rather than with the row's.
			s.names = sty():column():w(content - (theme:px(mobile ? 80 : 190))):h(s.coverSize):gap(theme:px(2))
			s.title = theme:s():wrel(1.0):text(theme:type("base")):weight("semibold"):fg(theme:color("text")):ellipsis()
			s.artist = theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()
			s.count = theme:s():text(theme:type("sm")):fg(theme:color("muted"))
			s.duration = theme:s():text(theme:type("sm")):fg(theme:color("faint"))
			s.none = sty():w(0):h(0)
		end
		for at = first, last do
			local album = albums[at]
			local actions = albumCard.actions(album)
			children[#children + 1] = div()
				:style(s.row)
				:hover(s.rowHover):onClick(actions.open)
				:onContextMenu(actions.menu)
				:children(
					{
						cover.view(app, { album = album, size = s.coverSize, radius = s.coverRadius }),
						div()
							:style(s.names)
							:children(
								{
									text(album.title):style(s.title),
									text(album.artist .. (album.year and (" · " .. album.year) or "")):style(s.artist)
								}
							),
						(not mobile) and text(format.count(#album.tracks, "track")):style(s.count) or div():style(s.none),
						(not mobile) and text(format.duration(album.duration)):style(s.duration) or div():style(s.none)
					}
				)
		end
	else
		if frameStyles.rowHeight ~= rowHeight or frameStyles.gap ~= gap then
			frameStyles.rowHeight, frameStyles.gap = rowHeight, gap
			frameStyles.gridRow = sty():row():wrel(1.0):h(rowHeight):gap(gap)
		end
		local gridRow = frameStyles.gridRow
		local row = {}
		for at = first, last do
			local album = albums[at]
			row[#row + 1] = albumCard.view(
				app,
				{
					album = album,
					width = cardWidth,
					ui = ctx
				}
			)
			if #row == columns or at == last then
				children[#children + 1] = div():style(gridRow):children(row)
				row = {}
			end
		end
	end

	local usedRows = last - first + 1
	local bottomPad = math.max(0, (totalRows - (first - 1) - usedRows) * rowHeight)
	if bottomPad > 0 then
		if frameStyles.bottomPadHeight ~= bottomPad then
			frameStyles.bottomPadHeight = bottomPad
			frameStyles.bottomPad = sty():h(bottomPad)
		end
		children[#children + 1] = div():style(frameStyles.bottomPad)
	end

	local columnHeight = totalRows * rowHeight
	if frameStyles.columnHeight ~= columnHeight then
		frameStyles.columnHeight = columnHeight
		frameStyles.column = sty():column():wrel(1.0):h(columnHeight):gap(0)
	end
	if frameStyles.contentHeight ~= contentHeight then
		frameStyles.contentHeight = contentHeight
		frameStyles.content = sty():column():wrel(1.0):h(contentHeight):gap(theme:space(18))
	end

	return div()
		:style(frameStyles.content)
		:children(header, div():style(frameStyles.column):children(children))
end

return libraryPage
