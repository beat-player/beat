-- Search is one field over artists, albums and tracks; with nothing typed it shows what was just
-- added, narrowed by whichever tags are selected.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local albumCard = require("beat.app.components.album_card")
local cover = require("beat.app.components.cover")
local tagPills = require("beat.app.components.tag_pills")
local trackRow = require("beat.app.components.track_row")
local metrics = require("beat.app.components.helpers.metrics")
local styles = require("beat.app.components.helpers.styles")
local searchField = require("beat.app.components.search_field")
local measure = require("beat.app.components.helpers.measure")
local format = require("beat.app.components.helpers.format")
local names = require("beat.music.names")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

--- The messages and props a result's row is built from, kept per track and per result list: the
--- page is built again on every scroll step, and a row is the same row until the search changes.
---@type table<beat.Track, table>
local trackRows = setmetatable({}, { __mode = "k" })

---@type { tracks: beat.Track[], ids: number[] }?
local idsCache

-- The words a result count becomes, kept by the count: the page is built again on every frame it
-- is scrolled, and "3 results found" does not change between them.
---@type table<number, string>
local foundTexts = {}

-- What a tag pill and an artist row send, made once per tag and per artist: a result list is
-- built again on every frame, and the message names the thing rather than the frame.
---@type table<beat.Tag, table>
local tagActions = setmetatable({}, { __mode = "k" })
---@type table<beat.Artist, table>
local artistActions = setmetatable({}, { __mode = "k" })

---@param tag beat.Tag
---@return table
local function tagAction(tag)
	local known = tagActions[tag]
	if known == nil then
		known = { type = "toggleTagFilter", id = tag.id }
		tagActions[tag] = known
	end
	return known
end

---@param artist beat.Artist
---@return table
local function artistAction(artist)
	local known = artistActions[artist]
	if known == nil then
		known = { type = "navigate", page = { kind = "artist", id = artist.id } }
		artistActions[artist] = known
	end
	return known
end

-- The props an artist result's cover is built from, written again for each row.
local artistCoverProps = {}

-- The section headings' props, written again for each heading: the component reads them and keeps
-- nothing, so one table serves every heading of the page.
local sectionProps = {}
local SEE_ALL_ALBUMS = { type = "navigate", page = { kind = "searchAll", category = "albums" } }
local SEE_ALL_ARTISTS = { type = "navigate", page = { kind = "searchAll", category = "artists" } }
local SEE_ALL_TRACKS = { type = "navigate", page = { kind = "searchAll", category = "tracks" } }

--- The title and the line under it, which never change with the frame.
---@class beat.pages.SearchIntroStyles
---@field title wonderland.StyleBuilder
---@field copy wonderland.StyleBuilder

---@param ctx beat.ui.Context
---@return beat.pages.SearchIntroStyles
local function introStyles(ctx)
	return {
		title = ctx:s():text(ctx:type("xxl")):weight("bold"):fg(ctx:color("text")),
		copy = ctx:s():text(ctx:type("sm")):fg(ctx:color("muted"))
	}
end

--- An artist result's row, kept for the theme: the same box, hover and words for every frame.
---@class beat.pages.SearchArtistStyles
---@field row wonderland.StyleBuilder
---@field hover wonderland.StyleBuilder
---@field art wonderland.StyleBuilder
---@field name wonderland.StyleBuilder

---@param ctx beat.ui.Context
---@return beat.pages.SearchArtistStyles
local function artistStyles(ctx)
	local theme = ctx.theme
	local size = theme:px(44)
	return {
		row = wonderland.sty():row():h(theme:px(56)):gap(theme:px(12)):align("center"):radius(theme:radius("sm")),
		hover = wonderland.sty()
			:row():h(theme:px(56)):gap(theme:px(12)):align("center"):radius(theme:radius("sm")):bg(theme:color("hover")),
		art = wonderland.sty():size(size, size):radius(theme:radius("full")):bg(theme:color("elevated")),
		name = theme:s():text(theme:type("base")):weight("semibold"):fg(theme:color("text"))
	}
end

-- The headings that never change.
local RECENTLY_ADDED = { title = "Recently added" }

---@class beat.pages.SearchFilterStyles
---@field label wonderland.StyleBuilder
---@field actions wonderland.StyleBuilder
---@field head wonderland.StyleBuilder
---@field allActive wonderland.StyleBuilder
---@field allIdle wonderland.StyleBuilder
---@field anyActive wonderland.StyleBuilder
---@field anyIdle wonderland.StyleBuilder
---@field clear wonderland.StyleBuilder
---@field allMessage table
---@field anyMessage table
---@field clearMessage table

---@type beat.PageSurface
local searchPage = {}

--- A phone opens this page with its own field in the keyboard's way: the top bar has no field
--- there, and a search screen that waits for a tap before taking a letter is a screen that asks
--- twice. Opening it from a tab starts a new search, so the last one's words go with the page
--- that showed them. A back from an album returns the page the history kept, which is the same
--- search and never comes through here.
---@param app beat.App
function searchPage.new(app)
	local window = app.window
	if window ~= nil and metrics.mobile(app, window.width) then
		app.services.search:clear()
		app:focusField("pageSearch", 0)
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
			action = tagAction,
			width = width,
			columns = columns
		}
	)
	if pills == nil then return nil, 0 end

	-- The words over the pills and the boxes they sit in do not change between frames: they are
	-- kept with the theme rather than made again on every scroll step.
	local filterStyles = styles.of(theme, "searchFilter") --[[@as beat.pages.SearchFilterStyles]]
	if filterStyles.label == nil then
		filterStyles.label = theme:s():wrel(1.0):text(theme:type("xs")):weight("bold"):fg(theme:color("muted"))
		filterStyles.actions = sty():row():w(theme:px(120)):gap(theme:px(8)):align("center"):justify("end")
		filterStyles.head = sty():row():wrel(1.0):h(theme:px(18)):justify("space-between"):align("center")
		filterStyles.allActive = theme:s():text(theme:type("xs")):weight("semibold"):fg(theme:color("accent"))
		filterStyles.allIdle = theme:s():text(theme:type("xs")):weight("semibold"):fg(theme:color("muted"))
		filterStyles.anyActive = filterStyles.allActive
		filterStyles.anyIdle = filterStyles.allIdle
		filterStyles.clear = theme:s():text(theme:type("xs")):weight("semibold"):fg(theme:color("accent"))
		filterStyles.allMessage = { type = "tagFilterMatch", value = "all" }
		filterStyles.anyMessage = { type = "tagFilterMatch", value = "any" }
		filterStyles.clearMessage = { type = "clearTagFilter" }
	end

	local headerActions = {}
	if next(search.tagFilter) ~= nil then
		headerActions[#headerActions + 1] = text("All")
			:style(search.match == "all" and filterStyles.allActive or filterStyles.allIdle)
			:onClick(filterStyles.allMessage)
		headerActions[#headerActions + 1] = text("Any")
			:style(search.match == "any" and filterStyles.anyActive or filterStyles.anyIdle)
			:onClick(filterStyles.anyMessage)
		headerActions[#headerActions + 1] = text("Clear"):style(filterStyles.clear):onClick(filterStyles.clearMessage)
	end

	local rows = math.ceil(#tags / columns)
	local height = theme:px(18) + theme:px(8) + rows * theme:px(28) + math.max(0, rows - 1) * theme:px(8) + theme:px(4)
	local boxSlot = styles.of(theme, "searchFilterBox", height) --[[@as { style: wonderland.StyleBuilder? }]]
	local box = boxSlot.style
	if box == nil then
		box = sty():column():wrel(1.0):h(height):gap(theme:px(8))
		boxSlot.style = box
	end
	return div()
		:style(assert(box))
		:children(
			div():style(filterStyles.head):children(
				text("Filter by tag"):style(filterStyles.label),
				div():style(filterStyles.actions):children(headerActions)
			),
			pills
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
	local cardHeight = albumCard.height(app, cardWidth)
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
			cards[#cards + 1] = albumCard.view(app, album, cardWidth, ctx)
		end
		local intro = styles.of(theme, "searchIntro", 0) --[[@as beat.pages.SearchIntroStyles]]
		if intro.title == nil then
			local built = introStyles(ctx)
			intro.title, intro.copy = built.title, built.copy
		end
		local shelf = styles.of(theme, "searchShelf", cardHeight) --[[@as { style: wonderland.StyleBuilder? }]]
		local shelfStyle = shelf.style
		if shelfStyle == nil then
			shelfStyle = sty():row():wrel(1.0):h(cardHeight):gap(gap)
			shelf.style = shelfStyle
		end
		local children = {
			text("Search your library"):style(intro.title),
			text("Artists, albums and tracks are all one field."):style(intro.copy),
			ui.section(ctx, RECENTLY_ADDED),
			div():style(assert(shelfStyle)):children(cards)
		}

		local idleHeight = cardHeight + theme:px(150)
		limit(idleHeight)
		local column = styles.of(theme, "searchColumn", idleHeight) --[[@as { style: wonderland.StyleBuilder?, gap: number? }]]
		local columnStyle = column.style
		if columnStyle == nil or column.gap ~= gap then
			column.gap = gap
			columnStyle = sty():column():wrel(1.0):h(idleHeight):gap(gap)
			column.style = columnStyle
		end
		return div():style(assert(columnStyle)):children(children)
	end

	local albums, artists, tracks = search:results()
	local albumLimit = math.min(#albums, columns * 2)
	local artistLimit = math.min(#artists, 10)
	local trackLimit = math.min(#tracks, 100)
	-- Each row sends the whole list with its click, so a tap queues the results from that row on
	-- rather than that one track alone.
	local trackIds = {}
	for at = 1, trackLimit do
		trackIds[at] = tracks[at].id
	end
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
	local current = app.services.playback:current()
	local playing = app.services.playback.player:isPlaying()
	local children = {}
	if found then
		-- The field already says what was searched for; this says how much it found.
		local foundText = foundTexts[total]
		if foundText == nil then
			foundText = format.count(total, "result") .. " found"
			foundTexts[total] = foundText
		end
		local foundStyle = styles.of(theme, "searchFoundText").style
		if foundStyle == nil then
			foundStyle = theme:s():wrel(1.0):h(countHeight):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()
			styles.of(theme, "searchFoundText").style = foundStyle
		end
		children[#children + 1] = text(foundText):style(foundStyle)
	end
	if filter ~= nil then children[#children + 1] = filter end

	if albumLimit > 0 then
		sectionProps.title, sectionProps.action = "Albums", nil
		if #albums > albumLimit then
			sectionProps.action = SEE_ALL_ALBUMS
		end
		children[#children + 1] = ui.section(ctx, sectionProps)
		local shelf = styles.of(theme, "searchShelf", cardHeight) --[[@as { style: wonderland.StyleBuilder? }]]
		local shelfStyle = shelf.style
		if shelfStyle == nil then
			shelfStyle = sty():row():wrel(1.0):h(cardHeight):gap(gap)
			shelf.style = shelfStyle
		end
		for rowAt = 1, albumRows do
			local row = {}
			for columnAt = 1, columns do
				local at = (rowAt - 1) * columns + columnAt
				local album = albums[at]
				if album ~= nil and at <= albumLimit then
					row[#row + 1] = albumCard.view(app, album, cardWidth, ctx)
				end
			end
			children[#children + 1] = div():style(assert(shelfStyle)):children(row)
		end
	end

	if artistLimit > 0 then
		sectionProps.title, sectionProps.action = "Artists", nil
		if #artists > artistLimit then
			sectionProps.action = SEE_ALL_ARTISTS
		end
		children[#children + 1] = ui.section(ctx, sectionProps)
		local artistBox = styles.of(theme, "searchArtist", 0) --[[@as beat.pages.SearchArtistStyles]]
		if artistBox.row == nil then
			local built = artistStyles(ctx)
			artistBox.row, artistBox.hover, artistBox.art, artistBox.name = built.row, built.hover, built.art, built.name
		end
		for at, artist in ipairs(artists) do
			if at > artistLimit then break end
			local top = artist.albums[1]
			local art
			if top ~= nil then
				artistCoverProps.album, artistCoverProps.size, artistCoverProps.radius = top, theme:px(44), theme:radius("full")
				art = cover.view(app, artistCoverProps --[[@as beat.components.CoverProps]])
			else
				art = div():style(artistBox.art)
			end
			children[#children + 1] = div()
				:style(artistBox.row)
				:hover(artistBox.hover)
				:onClick(artistAction(artist))
				:children(art, text(artist.name):style(artistBox.name))
		end
	end

	if trackLimit > 0 then
		sectionProps.title, sectionProps.action = "Tracks", nil
		if #tracks > trackLimit then
			sectionProps.action = SEE_ALL_TRACKS
		end
		children[#children + 1] = ui.section(ctx, sectionProps)
		local ids = idsCache
		if ids == nil or ids.tracks ~= tracks then
			ids = { tracks = tracks, ids = trackIds }
			idsCache = ids
		end
		for at, track in ipairs(tracks) do
			if at > trackLimit then break end
			local props = trackRows[track]
			if props == nil or props.ids ~= ids.ids then
				props = { track = track, onClick = { type = "playTrack", trackId = track.id, trackIds = ids.ids }, ids = ids.ids }
				trackRows[track] = props
			end
			props.index = at
			props.current = current ~= nil and current.id == track.id
			props.playing = playing
			props.width = content
			props.showAlbum = true
			props.showCover = true
			props.mobile = ctx.mobile
			props.ui = ctx
			children[#children + 1] = trackRow.view(app, props)
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
	local columnGap = theme:space(16)
	local column = styles.of(theme, "searchColumn", height) --[[@as { style: wonderland.StyleBuilder?, gap: number? }]]
	local columnStyle = column.style
	if columnStyle == nil or column.gap ~= columnGap then
		column.gap = columnGap
		columnStyle = sty():column():wrel(1.0):h(height):gap(columnGap)
		column.style = columnStyle
	end
	return div():style(assert(columnStyle)):children(children)
end

return searchPage
