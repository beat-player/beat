-- Search is one field over artists, albums and tracks; with nothing typed it shows what was just
-- added, narrowed by whichever tags are selected.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local albumCard = require("beat.app.components.album_card")
local cover = require("beat.app.components.cover")
local tagPills = require("beat.app.components.tag_pills")
local trackRow = require("beat.app.components.track_row")
local metrics = require("beat.app.components.helpers.metrics")
local searchField = require("beat.app.components.search_field")
local measure = require("beat.app.components.helpers.measure")
local format = require("beat.app.components.helpers.format")
local names = require("beat.music.names")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@type beat.PageSurface
local searchPage = {}

--- A phone opens this page with its own field in the keyboard's way: the top bar has no field
--- there, and a search screen that waits for a tap before taking a letter is a screen that asks
--- twice.
---@param app beat.App
function searchPage.new(app)
	local window = app.window
	if window ~= nil and metrics.mobile(app, window.width) then
		app:focusField("pageSearch", #app.services.search.query)
	end
	return {}
end

---@param app beat.App
---@param page beat.PageInstance
---@param message beat.Message
function searchPage.update(app, page, message)
	local search = app.services.search

	-- A tap on the field's clear mark is a press on the mark rather than in the field, and the
	-- keyboard follows the field: it is put back where the typing was.
	if message.type == "clearPageSearch" then
		search:clear()
		app:focusField("pageSearch", 0)
		app:refresh()
		return true
	end

	-- The Search tab on the page already showing has no route to take: the tab asks for the field
	-- it would have brought up, and the caret goes back to the end of what was typed.
	if message.type == "focusPageSearch" then
		app:focusField("pageSearch", #search.query)
		return true
	end

	-- Escape clears what was typed before it leaves the page. The field belongs to the search
	-- service; the page only decides that Escape means the field first.
	if message.type == "escape" and search.query ~= "" then
		search:clear()
		app:refresh()
		return true
	end
	return false
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
	local units = metrics.units(app, width)
	local columns = units >= 900 ? 6 : units >= 600 and 4 or 3
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

-- The phone's field: a thumb-sized pill with text read at arm's length.
local MOBILE_FIELD_HEIGHT = 48

--- How tall the pinned field is on this window: a phone's field, or none where the top bar has it.
---@param app beat.App
---@param window wonderland.RenderWindow
---@return number
local function pinnedHeight(app, window)
	local ctx = app:ui(window)
	if not ctx.mobile or app.services.library.current == nil then return 0 end
	return ctx:px(MOBILE_FIELD_HEIGHT)
end

--- On a phone the field is this page's, not the top bar's, and it stays at the top while the
--- results scroll under it. A desktop keeps the one in the top bar, which is already fixed.
---@param app beat.App
---@param page beat.PageInstance
---@param window wonderland.RenderWindow
---@return wonderland.Element?
---@return number
function searchPage.header(app, page, window)
	local height = pinnedHeight(app, window)
	if height == 0 then return nil, 0 end
	return searchField.view(
		app:ui(window),
		{
			name = "pageSearch",
			value = app.services.search.query,
			width = metrics.contentWidth(app, window.width),
			height = height,
			placeholder = "Artists, albums and tracks",
			clearMessage = { type = "clearPageSearch" }
		}
	), height
end

--- What a search that found nothing shows: a magnifier in a soft disc, what was looked for, and
--- the one way out. Every line is its own width and centred on the column, so short copy sits in
--- the middle rather than at the left of a fixed-width box.
---@param app beat.App
---@param ctx beat.ui.Context
---@param query string
---@param width number
---@return wonderland.Element
---@return number
local function noResults(app, ctx, query, width)
	local theme = app.services.appearance.theme
	local disc = theme:px(72)
	local titleSize = theme:type("lg")
	local copySize = theme:type("sm")
	local buttonHeight = theme:px(40)
	local height = theme:px(32) + disc + theme:px(18) + math.floor(titleSize * 1.3) + theme:px(6)
		+ math.floor(copySize * 1.4) + theme:px(20) + buttonHeight

	local function centred(element, lineHeight)
		return div():style(sty():row():wrel(1.0):h(lineHeight):justify("center"):align("center")):children({ element })
	end

	-- The query is the part of the title that can be any length: past the column it is cut, and
	-- only then given a width, so a title that fits is its own width and stays centred.
	local titleStyle = theme:s():text(titleSize):weight("bold"):fg(theme:color("text"))
	local title = "No results for “" .. query .. "”"
	local room = math.floor(width * 0.9)
	if (measure.width(app, title, titleStyle) or 0) > room then titleStyle = titleStyle:w(room):ellipsis() end

	return div()
		:style(sty():column():wrel(1.0):h(height):pad(theme:px(32), 0, 0, 0):align("center"))
		:children(
			{
				centred(
					div()
						:style(sty():size(disc, disc):radius(theme:radius("full")):bg(theme:color("accent", 0.12)):align("center"):justify("center"))
						:children(ui.icon(ctx, { name = "search", size = theme:px(30), colour = theme:color("accent") })),
					disc
				),
				div():style(sty():h(theme:px(18))),
				centred(
					text(title):style(titleStyle),
					math.floor(titleSize * 1.3)
				),
				div():style(sty():h(theme:px(6))),
				centred(
					text("Check the spelling, or try fewer words."):style(theme:s():text(copySize):fg(theme:color("muted"))),
					math.floor(copySize * 1.4)
				),
				div():style(sty():h(theme:px(20))),
				centred(
					ui.button(ctx, { label = "Clear search", onClick = { type = "clearSearch" }, height = buttonHeight, width = theme:px(140) }),
					buttonHeight
				)
			}
		), height
end

---@param app beat.App
---@param page beat.PageInstance
---@param window wonderland.RenderWindow
function searchPage.view(app, page, window)
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local search = app.services.search
	local library = app.services.library.current
	if library == nil then
		return ui.emptyState(
			ctx,
			{
				title = "Search your library",
				copy = "Choose a folder first.",
				actionLabel = "Choose a folder",
				action = { type = "chooseFolder" }
			}
		)
	end

	local content = metrics.contentWidth(app, window.width)
	local filter, filterHeight = searchTagFilter(app, content)
	local columns = metrics.gridColumns(app, content)
	local gap = theme:space(16)
	local cardWidth = math.max(120, math.floor((content - gap * (columns - 1)) / columns))
	local cardHeight = albumCard.height(app, { width = cardWidth })
	-- The phone's field is the pinned header's (see `searchPage.header`), so it is not part of what
	-- scrolls: the header's box comes out of the body's room, which is the same as asking the
	-- helper for that much more content. It is added to the height rather than to the answer
	-- because the helper clamps at zero, and a short page should not gain scroll from its header.
	local pinned = pinnedHeight(app, window)
	local function limit(contentHeight)
		local headerRoom = pinned > 0 and metrics.headerBox(app, pinned) or 0
		app.services.scroll:setLimit(app:pageKey(), metrics.pageScrollLimit(app, window, contentHeight + headerRoom))
	end

	if search.query == "" then
		local recent = library:recentlyAdded(columns)
		local filterIds = search:filterIds()
		if #filterIds > 0 then
			local taxonomy = app.services.collections.taxonomy
			local matching = {}
			for _, album in ipairs(recent) do
				local keep = false
				for _, track in ipairs(album.tracks) do
					if taxonomy:matches(names.trackKey(track), filterIds, search.match) then
						keep = true
						break
					end
				end
				if keep then matching[#matching + 1] = album end
			end
			recent = matching
		end
		local cards = {}
		for _, album in ipairs(recent) do
			---@cast album beat.Album
			cards[#cards + 1] = albumCard.view(
				app,
				{
					album = album,
					width = cardWidth,
					ui = ctx
				}
			)
		end
		local children = {}
		children[#children + 1] = text("Search your library"):style(
			theme:s():text(theme:type("xxl")):weight("bold"):fg(theme:color("text"))
		)
		children[#children + 1] = text("Artists, albums and tracks are all one field."):style(
			theme:s():text(theme:type("sm")):fg(theme:color("muted"))
		)
		children[#children + 1] = ui.section(ctx, { title = "Recently added" })
		children[#children + 1] = div():style(sty():row():wrel(1.0):h(cardHeight):gap(gap)):children(cards)

		local idleHeight = cardHeight + theme:px(150)
		limit(idleHeight)
		return div()
			:style(sty():column():wrel(1.0):h(idleHeight):gap(gap))
			:children(children)
	end

	local albums, artists, tracks = search:results()
	local albumLimit = math.min(#albums, columns * 2)
	local artistLimit = math.min(#artists, 10)
	local trackLimit = math.min(#tracks, 100)
	-- The phone's rows are the collection table's taller two-line rows, so the page's own content
	-- is that much taller too.
	local trackRowHeight = theme:px(ctx.mobile and 64 or 48)
	local albumRows = math.ceil(albumLimit / columns)
	local rowGap = theme:space(16)
	local sectionGap = theme:space(16)
	local sectionHeight = theme:px(24)
	local countHeight = theme:px(18)
	local height = countHeight + filterHeight
	if albumLimit > 0 then
		height = height + sectionGap + sectionHeight + sectionGap + albumRows * cardHeight + math.max(0, albumRows - 1) * rowGap
	end
	if artistLimit > 0 then
		height = height + sectionGap + sectionHeight + sectionGap + artistLimit * theme:px(56)
	end
	if trackLimit > 0 then
		height = height + sectionGap + sectionHeight + sectionGap + trackLimit * trackRowHeight
	end

	local total = #albums + #artists + #tracks
	local found = total > 0
	local children = {}
	if found then
		-- The field already says what was searched for; this says how much it found.
		children[#children + 1] = text(format.count(total, "result") .. " found")
			:style(theme:s():wrel(1.0):h(countHeight):text(theme:type("sm")):fg(theme:color("muted")):ellipsis())
	end
	if filter ~= nil then children[#children + 1] = filter end

	if albumLimit > 0 then
		children[#children + 1] = ui.section(
			ctx,
			{
				title = "Albums",
				action = #albums > albumLimit ? { type = "navigate", page = { kind = "searchAll", category = "albums" } } : nil
			}
		)
		for rowAt = 1, albumRows do
			local row = {}
			for columnAt = 1, columns do
				local at = (rowAt - 1) * columns + columnAt
				local album = albums[at]
				if album ~= nil and at <= albumLimit then
					row[#row + 1] = albumCard.view(
						app,
						{
							album = album,
							width = cardWidth,
							ui = ctx
						}
					)
				end
			end
			children[#children + 1] = div():style(sty():row():wrel(1.0):h(cardHeight):gap(gap)):children(row)
		end
	end

	if artistLimit > 0 then
		children[#children + 1] = ui.section(
			ctx,
			{
				title = "Artists",
				action = #artists > artistLimit ? { type = "navigate", page = { kind = "searchAll", category = "artists" } } : nil
			}
		)
		for at, artist in ipairs(artists) do
			if at > artistLimit then break end
			children[#children + 1] = div()
				:style(sty():row():h(theme:px(56)):gap(theme:px(12)):align("center"):radius(theme:radius("sm")))
				:hover(
					sty():row():h(theme:px(56)):gap(theme:px(12)):align("center"):radius(theme:radius("sm")):bg(theme:color("hover"))
				):onClick({ type = "navigate", page = { kind = "artist", id = artist.id } })
				:children(
					{
						artist.albums[1] ~= nil and cover.view(
							app,
							{ album = artist.albums[1], size = theme:px(44), radius = theme:radius("full") }
						) or div():style(sty():size(theme:px(44), theme:px(44)):radius(theme:radius("full")):bg(theme:color("elevated"))),
						text(artist.name):style(theme:s():text(theme:type("base")):weight("semibold"):fg(theme:color("text")))
					}
				)
		end
	end

	if trackLimit > 0 then
		children[#children + 1] = ui.section(
			ctx,
			{
				title = "Tracks",
				action = #tracks > trackLimit ? { type = "navigate", page = { kind = "searchAll", category = "tracks" } } : nil
			}
		)
		for at, track in ipairs(tracks) do
			if at > trackLimit then break end
			children[#children + 1] = trackRow.view(
				app,
				{
					track = track,
					index = at,
					current = app.services.playback:current() ~= nil and app.services.playback:current().id == track.id,
					playing = app.services.playback.player:isPlaying(),
					onClick = { type = "playTrack", trackId = track.id },
					width = content,
					showAlbum = true,
					showCover = true,
					mobile = ctx.mobile,
					ui = ctx
				}
			)
		end
	end

	if not found then
		-- The empty state says what was searched for itself, so it takes the title's place.
		local empty, emptyHeight = noResults(app, ctx, search.query, content)
		height = height - countHeight + emptyHeight
		children[#children + 1] = empty
	end

	height = height + theme:space(24)
	limit(height)
	return div():style(sty():column():wrel(1.0):h(height):gap(theme:space(16))):children(children)
end

return searchPage
