-- Everything search found in one category, scrolled as a grid of albums or a list of artists or
-- tracks.
local wonderland = require("wonderland")
local format = require("beat.app.components.helpers.format")
local albumCard = require("beat.app.components.album_card")
local cover = require("beat.app.components.cover")
local emptyState = require("beat.app.components.empty_state")
local tagPills = require("beat.app.components.tag_pills")
local trackRow = require("beat.app.components.track_row")
local metrics = require("beat.app.components.helpers.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@type beat.PageSurface
local searchAll = {}

--- Two searches of different categories are different pages: they keep their own scroll.
---@param page beat.PageKey
function searchAll.key(page)
	return "searchAll:" .. (page.category or "")
end

--- The tag filters under search. Selecting more than one narrows to tracks that have all of
--- them; the Playlists page has the same idea as a saved smart playlist.
---@param app beat.App
---@param width number
---@return wonderland.Element?
---@return number
local function searchTagFilter(app, width)
	local tags = app.services.collections.taxonomy:visibleTags()
	if #tags == 0 then return nil, 0 end
	local theme = app.services.appearance.theme
	local search = app.services.search
	local columns = width >= 900 ? 6 : width >= 600 and 4 or 3
	local pills = tagPills.view(
		app,
		{
			tags = tags,
			selected = search.tagFilter,
			action = |tag| -> { type = "toggleTagFilter", id = tag.id },
			width = width,
			columns = columns
		}
	)
	if pills == nil then return nil, 0 end

	local headerActions = {}
	if next(search.tagFilter) ~= nil then
		headerActions[#headerActions + 1] = text("All")
			:style(
				theme:s()
					:text(theme:type("xs")):weight("semibold")
					:fg(search.match == "all" ? (theme:color("accent")) : (theme:color("muted")))
			):onClick({ type = "tagFilterMatch", value = "all" })
		headerActions[#headerActions + 1] = text("Any")
			:style(
				theme:s()
					:text(theme:type("xs")):weight("semibold")
					:fg(search.match == "any" ? (theme:color("accent")) : (theme:color("muted")))
			):onClick({ type = "tagFilterMatch", value = "any" })
		headerActions[#headerActions + 1] = text("Clear")
			:style(theme:s():text(theme:type("xs")):weight("semibold"):fg(theme:color("accent")))
			:onClick({ type = "clearTagFilter" })
	end
	local headerChildren = {
		text("Filter by tag"):style(theme:s():wrel(1.0):text(theme:type("xs")):weight("bold"):fg(theme:color("muted"))),
		div():style(sty():row():w(theme:px(120)):gap(theme:px(8)):align("center"):justify("end")):children(headerActions)
	}

	local rows = math.ceil(#tags / columns)
	local height = theme:px(18) + theme:px(8) + rows * theme:px(28) + math.max(0, rows - 1) * theme:px(8) + theme:px(4)
	return div()
		:style(sty():column():wrel(1.0):h(height):gap(theme:px(8)))
		:children(
			{
				div():style(sty():row():wrel(1.0):h(theme:px(18)):justify("space-between"):align("center")):children(headerChildren),
				pills
			}
		), height
end

---@param app beat.App
---@param page beat.PageInstance
---@param window wonderland.RenderWindow
function searchAll.view(app, page, window)
	local category = page.category
	local theme = app.services.appearance.theme
	local search = app.services.search
	local library = app.services.library.current
	if library == nil then
		return emptyState.view(
			app,
			{
				title = "Search your library",
				copy = "Choose a folder first.",
				actionLabel = "Choose a folder",
				action = { type = "chooseFolder" }
			}
		)
	end
	if search.query == "" then
		return emptyState.view(app, { title = "Search your library", copy = "Artists, albums and tracks are all one field." })
	end

	local albums, artists, tracks = search:results()
	local items = category == "albums" and albums or category == "artists" and artists or tracks
	local width = metrics.contentWidth(app, window.width)
	local filter, filterHeight = searchTagFilter(app, width)
	local gap = theme:space(16)
	local columns = metrics.gridColumns(width)
	local cardWidth = math.max(120, math.floor((width - gap * (columns - 1)) / columns))
	local cardHeight = albumCard.height(app, { width = cardWidth })
	local headerHeight = theme:px(58) + filterHeight
	local listStart = headerHeight + gap + (filter ~= nil and gap or 0)
	local rowHeight, perRow
	if category == "albums" then
		rowHeight = cardHeight + gap
		perRow = columns
	elseif category == "artists" then
		rowHeight = theme:px(64)
		perRow = 1
	else
		rowHeight = theme:px(54)
		perRow = 1
	end

	local count = #items
	local totalRows = category == "albums" ? math.ceil(count / columns) : count
	local viewport = metrics.viewportHeight(app, window.width, window.height)
	local scroll = app.services.scroll:offset(app:pageKey())
	local first, last, top = app.services.scroll.slices(
		count,
		perRow,
		rowHeight,
		math.max(0, scroll - listStart),
		viewport
	)
	---@cast first number
	---@cast last number
	---@cast top number

	local label = category == "albums" and "All albums" or category == "artists" and "All artists" or "All tracks"
	local headerChildren = {
		text(label):style(theme:s():text(theme:type("xxl")):weight("bold"):fg(theme:color("text"))),
		text(
			format.count(count, category == "albums" and "album" or category == "artists" and "artist" or "track") .. " for \"" .. search.query .. "\""
		)
			:style(theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis())
	}
	if filter ~= nil then headerChildren[#headerChildren + 1] = filter end
	local header = div():style(sty():column():wrel(1.0):h(headerHeight):gap(theme:px(4))):children(headerChildren)

	local list = {}
	if top > 0 then list[#list + 1] = div():style(sty():h(top)) end

	if category == "albums" then
		local row = {}
		for at = first, last do
			local album = albums[at]
			if album ~= nil then
				row[#row + 1] = albumCard.view(
					app,
					{
						album = album,
						width = cardWidth,
						onOpen = { type = "navigate", page = { kind = "album", id = album.id } },
						onPlay = { type = "playAlbum", id = album.id }
					}
				)
			end
			if #row == columns or at == last then
				list[#list + 1] = div():style(sty():row():wrel(1.0):h(rowHeight):gap(gap)):children(row)
				row = {}
			end
		end
	elseif category == "artists" then
		for at = first, last do
			local artist = artists[at]
			if artist ~= nil then
				list[#list + 1] = div()
					:style(sty():row():wrel(1.0):h(rowHeight):gap(theme:px(12)):align("center"):radius(theme:radius("sm")))
					:hover(
						sty()
							:row():wrel(1.0):h(rowHeight):gap(theme:px(12)):align("center"):radius(theme:radius("sm"))
							:bg(theme:color("hover"))
					):onClick({ type = "navigate", page = { kind = "artist", id = artist.id } })
					:children(
						{
							artist.albums[1] ~= nil and cover.view(
								app,
								{ album = artist.albums[1], size = theme:px(44), radius = theme:radius("full") }
							) or div():style(sty():size(theme:px(44), theme:px(44)):radius(theme:radius("full")):bg(theme:color("elevated"))),
							text(artist.name):style(theme:s():text(theme:type("base")):weight("semibold"):fg(theme:color("text")):ellipsis())
						}
					)
			end
		end
	else
		for at = first, last do
			local track = tracks[at]
			if track ~= nil then
				list[#list + 1] = div()
					:style(sty():wrel(1.0):h(rowHeight))
					:children(
						{
							trackRow.view(
								app,
								{
									track = track,
									index = at,
									current = app.services.playback:current() ~= nil and app.services.playback:current().id == track.id,
									playing = app.services.playback.player:isPlaying(),
									onClick = { type = "playTrack", trackId = track.id },
									width = width,
									showAlbum = true
								}
							)
						}
					)
			end
		end
	end

	local contentHeight = listStart + totalRows * rowHeight
	app.services.scroll:setLimit(
		app:pageKey(),
		math.max(0, contentHeight - metrics.viewportHeight(app, window.width, window.height))
	)
	return div()
		:style(sty():column():wrel(1.0):h(contentHeight):gap(gap))
		:children({ header, div():style(sty():column():wrel(1.0):h(totalRows * rowHeight)):children(list) })
end

return searchAll
