-- One collection is a cover, a title block, and a track table. Albums and playlist pages
-- differ in the words and the one extra control they offer, not in how the page is built.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local trackRow = require("beat.app.components.track_row")
local spinner = require("beat.app.components.spinner")
local metrics = require("beat.app.components.helpers.metrics")
local measure = require("beat.app.components.helpers.measure")
local names = require("beat.music.names")
local styles = require("beat.app.components.helpers.styles")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local collection = {}

--- The boxes of one collection's header and table, kept for the layout they were built from: the
--- page is built again every time it is scrolled, and all of these depend on the window's geometry
--- and the collection's shape rather than on a value that moves.
---@class beat.components.CollectionStyles
---@field content number
---@field mobile boolean
---@field phoneHero boolean
---@field stacked boolean
---@field hasSubtitle boolean
---@field contentHeight number
---@field heroHeight number
---@field coverSize number
---@field infoHeight number
---@field cover wonderland.StyleBuilder
---@field play wonderland.StyleBuilder
---@field info wonderland.StyleBuilder
---@field labelRow wonderland.StyleBuilder
---@field actionsRow wonderland.StyleBuilder
---@field hero wonderland.StyleBuilder
---@field artRow wonderland.StyleBuilder
---@field list wonderland.StyleBuilder
---@field headerRow wonderland.StyleBuilder
---@field column wonderland.StyleBuilder
---@field labelText wonderland.StyleBuilder
---@field headerHash wonderland.StyleBuilder
---@field headerTitle wonderland.StyleBuilder
---@field headerRating wonderland.StyleBuilder
---@field headerTime wonderland.StyleBuilder
---@field moreBox wonderland.StyleBuilder
---@field titleWidth number?
---@field metaWidth number?
---@field subtitleWidth number?

--- The table's header cells, kept for the columns the table has room for.
---@class beat.components.CollectionHeader
---@field ratingWidth number?
---@field mobile boolean
---@field hash wonderland.StyleBuilder
---@field title wonderland.StyleBuilder
---@field rating wonderland.StyleBuilder?
---@field time wonderland.StyleBuilder
---@field more wonderland.StyleBuilder?
---@field row wonderland.StyleBuilder

--- The lines under the header, kept with the words they were measured for.
---@class beat.components.CollectionLines
---@field titleText string
---@field metaText string
---@field subtitleText string?
---@field phoneHero boolean
---@field mobile boolean
---@field title wonderland.StyleBuilder
---@field meta wonderland.StyleBuilder
---@field subtitle wonderland.StyleBuilder?

--- The props a track's row is built from, kept per track: the rows are built again whenever the
--- page is scrolled, and only the fields written in the loop below change between frames.
---@type table<beat.Track, beat.components.TrackRowProps>
local rowProps = setmetatable({}, { __mode = "k" })

---@param app beat.App
---@param content number
---@param value string
---@param style wonderland.StyleBuilder
---@param size number
local function fittedWidth(app, content, value, style, size)
	local known = measure.width(app, value, style)
	if known == nil then
		known = measure.estimate(value, size, 0.52)
	end
	return math.min(content, math.max(1, math.ceil(assert(known)) + app.services.appearance.theme:px(2)))
end

---@class beat.components.CollectionProps
---@field window wonderland.RenderWindow
---@field label string # The word above the title: ALBUM, PLAYLIST
---@field icons wonderland.Element? # Marks drawn beside the label
---@field cover fun(size: number): wonderland.Element # The square above the title block
---@field coverMenu fun(x: number, y: number, width: number, height: number, modifiers: any?, windowX: number, windowY: number): any? # The menu a right-click on the cover opens
---@field title string
---@field subtitle string? # The line under the title; none leaves it out
---@field subtitleAction any? # The message a click on the subtitle sends
---@field meta string
---@field playAction any
---@field playIcon string
---@field loading boolean? # Whether the collection's hero play is waiting for a track to be heard
---@field shuffleAction any
---@field shuffleMenu any? # The shuffle-mode menu a right-click or long press on the button opens
---@field addAction any? # The extra control, when the collection can grow by hand
---@field rating number? # The collection's own stars, 0 to 5, drawn beside the buttons
---@field onRate (fun(stars: number): any)? # The message for setting them; without it there are no header stars
---@field tracks beat.Track[]
---@field trackAction fun(track: beat.Track, at: number): any
---@field trackIndex (fun(track: beat.Track, at: number): number)? # The number a row shows; default its place
---@field empty wonderland.Element? # What the table shows when there are no tracks
---@field titleOnly boolean? # Rows show titles only; the header names the artist
---@field ratings boolean? # Rows show each track's stars, and set them
---@field phoneHero boolean? # On a phone, a large centred cover above a centred title block

---@param app beat.App
---@param props beat.components.CollectionProps
---@return wonderland.Element
function collection.view(app, props)
	local window = props.window
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local mobile = metrics.mobile(app, window.width)
	-- The stars belong to the ratings plugin. Without it the collection keeps its data but draws
	-- no control for it, so the album and playlist pages do not have to know about the plugin.
	local ratings = app.registry:hasPlugin("ratings")
	-- A phone's album header is the cover, large, with the title block beneath it -- there is no
	-- rail beside it to sit against, and the cover is the page's one picture.
	local phoneHero = mobile and props.phoneHero == true
	local stacked = mobile and (phoneHero or window.height >= theme:px(560))
	local content = metrics.contentWidth(app, window.width)
	local coverSize
	if phoneHero then
		coverSize = math.min(theme:px(320), content)
	elseif stacked then
		coverSize = math.min(theme:px(150), content)
	elseif mobile then
		coverSize = math.min(theme:px(120), math.floor(content * 0.25))
	else
		coverSize = math.min(theme:px(224), math.floor(content * 0.32))
	end
	local titleSize = (theme:type(mobile ? "xxl" : "hero"))
	local labelHeight = theme:px(16)
	local titleHeight = math.floor(titleSize * 1.25)
	-- A collection without a subtitle has no line for one, and the gap that would sit above it goes too.
	local hasSubtitle = props.subtitle ~= nil
	local subtitleHeight = hasSubtitle and math.floor(theme:type("md") * 1.3) or 0
	local metaHeight = math.floor(theme:type("sm") * 1.3)
	local actionsHeight = theme:px(52)
	local infoHeight = labelHeight + titleHeight + subtitleHeight + metaHeight + actionsHeight + theme:px(8) * (hasSubtitle and 4 or 3)
	local heroHeight
	if phoneHero then
		-- The cover clears the top bar's shadow and the page's own padding before it begins.
		heroHeight = theme:space(24) + coverSize + theme:space(16) + infoHeight
	elseif stacked then
		heroHeight = coverSize + theme:space(16) + infoHeight
	else
		heroHeight = coverSize + (theme:space(mobile ? 70 : 90))
	end
	local hasTracks = #props.tracks > 0
	local rowHeight = mobile and theme:px(64) or theme:px(48)
	local rowsHeight = hasTracks and #props.tracks * rowHeight or (props.empty ~= nil and theme:px(120) or 0)
	-- The table's own parts, in the order the page stacks them: the gap above the table, its
	-- header, its rows and the gap below. The slice's start offset and the page's height both use
	-- these, so the phone's taller rows are counted once in each place and nowhere else.
	local listPadTop = theme:space(20)
	local listPadBottom = theme:space(24)
	local tableHeaderHeight = hasTracks and theme:px(34) or 0
	local trackListHeight = listPadTop + tableHeaderHeight + rowsHeight + listPadBottom
	local contentHeight = heroHeight + trackListHeight
	local current = app.services.playback:current()
	local playing = app.services.playback.player:isPlaying()
	local loading = app.services.playback:isLoading()

	-- The boxes and the header's cells depend on the window, the theme and the collection's shape,
	-- not on anything that moves: they are kept for that shape and handed over again on the next
	-- frame, rather than a fresh builder being interned for every scroll step. The heights are part
	-- of the shape -- two albums of different lengths share this record, and a column kept at the
	-- first album's height is one the next album's rows cannot be scrolled down past.
	local style = styles.of(theme, "collection", content) --[[@as beat.components.CollectionStyles]]
	if
		style.mobile ~= mobile
		or style.phoneHero ~= phoneHero
		or style.stacked ~= stacked
		or style.hasSubtitle ~= hasSubtitle
		or style.contentHeight ~= contentHeight
		or style.heroHeight ~= heroHeight
		or style.coverSize ~= coverSize
		or style.infoHeight ~= infoHeight
	then
		style.mobile, style.phoneHero, style.stacked, style.hasSubtitle = mobile, phoneHero, stacked, hasSubtitle
		style.contentHeight, style.heroHeight = contentHeight, heroHeight
		style.coverSize, style.infoHeight = coverSize, infoHeight
		style.cover = sty():size(coverSize, coverSize):radius(theme:radius("lg"))
		style.play = sty()
			:size(theme:px(52), theme:px(52)):radius(theme:radius("full")):bg(theme:color("accent")):align("center")
			:justify("center")
		style.info = phoneHero
				and (sty():column():h(infoHeight):justify("center"):align("center"):gap(theme:px(8)):w(content))
			or (sty():column():h(stacked and infoHeight or heroHeight):justify("center"):gap(theme:px(8)):wrel(1.0))
		style.labelRow = phoneHero
				and (sty():row():h(theme:px(16)):gap(theme:px(7)):align("center"):justify("center"))
			or (sty():row():h(theme:px(16)):gap(theme:px(7)):align("center"))
		style.actionsRow = phoneHero
				and (sty():row():h(theme:px(52)):gap(theme:px(10)):align("center"):justify("center"))
			or (sty():row():h(theme:px(52)):gap(theme:px(10)):align("center"))
		if phoneHero then
			style.hero = sty():column():wrel(1.0):h(heroHeight):pad(theme:space(24), 0, 0, 0):gap(theme:space(16))
		elseif stacked then
			style.hero = sty():column():wrel(1.0):h(heroHeight):gap(theme:space(16))
		else
			style.hero = sty():row():wrel(1.0):h(heroHeight):pad(0, 0, 0, 0):gap(theme:space(28)):align("center")
		end
		style.artRow = sty():row():wrel(1.0):h(coverSize):justify("center")
		style.list = sty():column():wrel(1.0):h(trackListHeight):pad(listPadTop, 0, listPadBottom, 0)
		style.column = sty():column():wrel(1.0):h(contentHeight)
		style.labelText = theme:s():text(theme:type("xs")):weight("bold"):fg(theme:color("muted"))
	end

	local cover = div():style(style.cover)
	if props.coverMenu ~= nil then cover:onContextMenu(props.coverMenu) end
	cover:children(props.cover(coverSize))

	local labelChildren = { text(props.label):style(style.labelText) }
	if props.icons ~= nil then labelChildren[#labelChildren + 1] = props.icons end

	-- The title, subtitle and meta lines, kept with the words they were measured for: on a phone
	-- each of them is as wide as its own ink rather than the page's width.
	local lines = styles.of(theme, "collectionLines", content) --[[@as beat.components.CollectionLines]]
	local subtitleText = props.subtitle
	-- The title size follows the phone breakpoint, not the content width alone: a desktop and a
	-- phone can share this record at the same content width, and the lines measured for one
	-- breakpoint are the wrong width for the other.
	if
		lines.titleText ~= props.title
		or lines.metaText ~= props.meta
		or lines.subtitleText ~= subtitleText
		or lines.phoneHero ~= phoneHero
		or lines.mobile ~= mobile
	then
		lines.titleText, lines.metaText, lines.subtitleText, lines.phoneHero = props.title, props.meta, subtitleText, phoneHero
		lines.mobile = mobile
		local titleStyle = theme:s():text(titleSize):weight("bold"):fg(theme:color("text")):ellipsis()
		local metaStyle = theme:s():text(theme:type("sm")):fg(theme:color("muted")):ellipsis()
		if phoneHero then
			titleStyle:w(fittedWidth(app, content, props.title, titleStyle, titleSize))
			metaStyle:w(fittedWidth(app, content, props.meta, metaStyle, theme:type("sm")))
		else
			metaStyle:wrel(1.0)
		end
		lines.title, lines.meta = titleStyle, metaStyle
		if subtitleText ~= nil then
			local subtitleStyle = theme:s():text(theme:type("md")):weight("semibold"):fg(theme:color("text")):ellipsis()
			if phoneHero then
				subtitleStyle:w(fittedWidth(app, content, subtitleText, subtitleStyle, theme:type("md")))
			else
				subtitleStyle:wrel(1.0)
			end
			lines.subtitle = subtitleStyle
		else
			lines.subtitle = nil
		end
	end

	---@type wonderland.Element?
	local subtitle = nil
	if subtitleText ~= nil then
		subtitle = text(subtitleText):style(assert(lines.subtitle))
		if props.subtitleAction ~= nil then subtitle:onClick(props.subtitleAction) end
	end

	local playMark = props.loading
			and spinner.view(app, theme:px(24), theme.accentInk)
		or ui.icon(ctx, { name = props.playIcon, size = theme:px(24), colour = theme.accentInk })
	local shuffle = ui.iconButton(ctx, { name = "shuffle", size = theme:px(30), onClick = props.shuffleAction })
	if props.shuffleMenu ~= nil then shuffle:onContextMenu(props.shuffleMenu) end
	local actions = {
		div():style(style.play):onClick(props.playAction):children(playMark),
		shuffle
	}
	if props.addAction ~= nil then
		actions[#actions + 1] = ui.iconButton(ctx, { name = "add", size = theme:px(30), onClick = props.addAction })
	end
	if props.onRate ~= nil and ratings then
		-- Set a little apart from the buttons, and larger than a row's stars, so it reads as the
		-- collection's own rating rather than one more control or one of its tracks'.
		actions[#actions + 1] = div():style(sty():w(theme:px(6)))
		actions[#actions + 1] = ui.rating(ctx, { value = props.rating or 0, onRate = props.onRate, size = theme:px(20) })
	end

	--- The info column's lines in order, the subtitle only where there is one.
	local info = div():style(style.info)
	info:children(
		div():style(style.labelRow):children(labelChildren),
		text(props.title):style(lines.title)
	)
	if subtitle ~= nil then info:children(subtitle) end
	info:children(text(props.meta):style(lines.meta), div():style(style.actionsRow):children(actions))

	local hero = div():style(style.hero)
	if phoneHero or stacked then
		hero:children(div():style(style.artRow):children(cover), info)
	else
		hero:children(cover, info)
	end

	local rows = {}
	local ratingWidth = props.ratings and ratings and trackRow.ratingWidth(app, content, mobile) or nil
	if hasTracks then
		local head = styles.of(theme, "collectionHeader", content) --[[@as beat.components.CollectionHeader]]
		if head.ratingWidth ~= ratingWidth or head.mobile ~= mobile then
			head.ratingWidth, head.mobile = ratingWidth, mobile
			local moreColumn = mobile and theme:px(44) + theme:px(12) or 0
			head.hash = theme:s():w(theme:px(24)):text(theme:type("xs")):weight("bold"):fg(theme:color("faint"))
			head.title = theme:s()
				:w(content - theme:px(122) - moreColumn - (ratingWidth ~= nil and ratingWidth + theme:px(12) or 0))
				:text(theme:type("xs")):weight("bold"):fg(theme:color("faint"))
			head.rating = ratingWidth ~= nil
				and (theme:s():w(ratingWidth):text(theme:type("xs")):weight("bold"):fg(theme:color("faint")))
				or nil
			head.time = theme:s():w(theme:px(54)):text(theme:type("xs")):weight("bold"):fg(theme:color("faint"))
			head.more = mobile and sty():w(theme:px(44)) or nil
			head.row = sty():row():w(content):h(tableHeaderHeight):pad(0, theme:px(10), 0, theme:px(10)):gap(theme:px(12))
				:align("center")
		end
		local headerRow = div():style(head.row):children(text("#"):style(head.hash), text("TITLE"):style(head.title))
		if head.rating ~= nil then headerRow:children(text("RATING"):style(head.rating)) end
		headerRow:children(text("TIME"):style(head.time))
		if head.more ~= nil then headerRow:children(div():style(head.more)) end
		rows[#rows + 1] = headerRow
	end

	local viewport = metrics.viewportHeight(app, window.width, window.height)
	-- The helper counts the shell's top padding above the content and a margin under it, so the
	-- last row still reaches the fold and comes to rest clear of the bottom bar.
	local limit = metrics.pageScrollLimit(app, window, contentHeight)
	app.services.scroll:setLimit(app:pageKey(), limit)
	-- An offset kept from a taller layout is clamped here too, so a page that grew shorter does
	-- not open scrolled past its own list.
	local scroll = math.min(app.services.scroll:offset(app:pageKey()), limit)
	local trackStart = heroHeight + listPadTop + tableHeaderHeight
	local first, last, top = app.services.scroll.slices(
		#props.tracks,
		1,
		rowHeight,
		math.max(0, scroll - trackStart),
		viewport
	)

	if top > 0 then rows[#rows + 1] = div():style(sty():h(top)) end
	for at = first, last do
		local track = props.tracks[at]
		if track ~= nil then
			local kept = rowProps[track]
			if kept == nil then
				---@type beat.components.TrackRowProps
				kept = { track = track, showAlbum = false }
				rowProps[track] = kept
			end
			kept.index = props.trackIndex ~= nil ? props.trackIndex(track, at) : at
			kept.current = current?.id == track.id
			kept.playing = playing
			kept.loading = kept.current and loading
			kept.onClick = props.trackAction(track, at)
			kept.width = content
			kept.titleOnly = props.titleOnly
			kept.rating = props.ratings and ratings and app.services.collections.taxonomy:rating(names.trackKey(track)) or nil
			kept.mobile = mobile
			kept.ui = ctx
			rows[#rows + 1] = trackRow.view(app, kept --[[@as beat.components.TrackRowProps]])
		end
	end
	if #props.tracks == 0 and props.empty ~= nil then rows[#rows + 1] = props.empty end

	return div():style(style.column):children(hero, div():style(style.list):children(rows))
end

return collection
