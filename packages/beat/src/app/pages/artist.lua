-- The artist screen: a hero of their first cover, their top tracks, and every album.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local format = require("beat.app.components.helpers.format")
local albumCard = require("beat.app.components.album_card")
local cover = require("beat.app.components.cover")
local trackRow = require("beat.app.components.track_row")
local metrics = require("beat.app.components.helpers.metrics")
local styles = require("beat.app.components.helpers.styles")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.pages.ArtistStyles
---@field content number
---@field heroSize number
---@field heroHeight number
---@field topHeight number
---@field albumsHeight number
---@field contentHeight number
---@field hero wonderland.StyleBuilder
---@field art wonderland.StyleBuilder
---@field nameColumn wonderland.StyleBuilder
---@field label wonderland.StyleBuilder
---@field name wonderland.StyleBuilder
---@field count wonderland.StyleBuilder
---@field actionsRow wonderland.StyleBuilder
---@field play wonderland.StyleBuilder
---@field playLabel wonderland.StyleBuilder
---@field topBox wonderland.StyleBuilder
---@field albumRow wonderland.StyleBuilder
---@field column wonderland.StyleBuilder
---@field albumColumn wonderland.StyleBuilder
---@field topTitle string? # The counts the words were made for
---@field topCount number?
---@field albumCount number?
---@field counts string?

--- The boxes and text styles of the page, kept for the window and the artist's shape: a page is
--- built again on every scroll step, and these depend on neither the scroll nor the frame.
---@param theme beat.Theme
---@param content number
---@param heroSize number
---@param heroHeight number
---@param albumsHeight number
---@param contentHeight number
---@param topHeight number
---@return beat.pages.ArtistStyles
local function pageStyles(theme, content, heroSize, heroHeight, albumsHeight, contentHeight, topHeight)
	local kept = styles.of(theme, "artistPage", content) --[[@as beat.pages.ArtistStyles]]
	if
		kept.heroSize == heroSize
		and kept.heroHeight == heroHeight
		and kept.topHeight == topHeight
		and kept.albumsHeight == albumsHeight
		and kept.contentHeight == contentHeight
	then
		return kept
	end
	local gap = theme:space(16)
	local radius = theme:radius("lg")
	kept.content, kept.heroSize, kept.heroHeight = content, heroSize, heroHeight
	kept.topHeight, kept.albumsHeight, kept.contentHeight = topHeight, albumsHeight, contentHeight
	kept.hero = sty():row():wrel(1.0):h(heroHeight):pad(0, 0, 0, 0):gap(theme:space(24)):align("center")
	kept.art = sty():size(heroSize, heroSize):radius(radius):bg(theme:color("elevated"))
	kept.nameColumn = sty():column():h(heroHeight):justify("center"):gap(theme:px(8))
	kept.label = theme:s():text(theme:type("xs")):weight("bold"):fg(theme:color("muted"))
	kept.name = theme:s():text(theme:type("hero")):weight("bold"):fg(theme:color("text"))
	kept.count = theme:s():text(theme:type("sm")):fg(theme:color("muted"))
	kept.actionsRow = sty():row():h(theme:px(38)):gap(theme:px(10)):align("center")
	kept.play = sty()
		:size(theme:px(38), theme:px(38)):radius(theme:radius("full")):bg(theme:color("accent")):align("center")
		:justify("center")
	kept.playLabel = theme:s():text(theme:type("sm")):weight("semibold"):fg(theme:color("text"))
	kept.topBox = sty():column():wrel(1.0):h(topHeight):gap(2)
	kept.albumRow = sty():row():wrel(1.0):h("auto"):gap(gap)
	kept.albumColumn = sty():column():wrel(1.0):h(albumsHeight):gap(gap)
	kept.column = sty():column():wrel(1.0):h(contentHeight):gap(theme:space(24))
	return kept
end

--- The props an album's cover is built from, written again each time: the cover reads them and
--- keeps nothing, and the shelf is built on every frame it is scrolled.
---@type table<string, any>
local heroCoverProps = { radius = 0, glow = true }

-- What the Play all control sends, made once per artist: the page is built again on every frame.
---@type table<beat.Artist, table>
local playActions = setmetatable({}, { __mode = "k" })

---@param artist beat.Artist
---@return table
local function playAction(artist)
	local known = playActions[artist]
	if known == nil then
		known = { type = "playArtist", id = artist.id }
		playActions[artist] = known
	end
	return known
end

--- A top track's row props and the message it sends, kept per track: the same six rows are handed
--- over again on every frame, and only what is playing changes.
---@class beat.pages.ArtistTrackRow
---@field props beat.components.TrackRowProps
---@field artistId number

---@type table<beat.Track, beat.pages.ArtistTrackRow>
local topRows = setmetatable({}, { __mode = "k" })

---@param track beat.Track
---@param artistId number
---@return beat.components.TrackRowProps
local function topRow(track, artistId)
	local known = topRows[track]
	if known == nil or known.artistId ~= artistId then
		local message = { type = "playTrack", trackId = track.id, artistId = artistId }
		local made = { artistId = artistId, props = { track = track, onClick = message, showAlbum = true } }
			--[[@as beat.pages.ArtistTrackRow]]
		topRows[track] = made
		known = made
	end
	return (known --[[@as beat.pages.ArtistTrackRow]]).props
end

---@type beat.PageSurface
local artistPage = {}

---@param page beat.PageInstance
---@return string
function artistPage.key(page)
	return "artist:" .. tostring(page.id)
end

--- Read from the library each frame: a page kept in the history outlives the scan that made
--- it, and says so rather than showing an artist that is gone.
---@param app beat.App
---@param page beat.PageInstance
---@param window wonderland.RenderWindow
---@return wonderland.Element
function artistPage.view(app, page, window)
	local id = assert(page.id)
	local ctx = app:ui(window)
	local library = app.services.library.current
	local artist = library ~= nil ? (library:artist(id)) : nil
	if artist == nil then
		return ui.emptyState(
			ctx,
			{
				title = "Artist not found",
				copy = "The scan no longer has them.",
				actionLabel = "Library",
				action = { type = "navigate", page = { kind = "library" } }
			}
		)
	end
	local theme = app.services.appearance.theme
	local content = metrics.contentWidth(app, window.width)
	local heroSize = math.min(theme:px(160), math.floor(content * 0.24))
	local heroHeight = heroSize + theme:space(24)
	local album = artist.albums[1]
	local columns = metrics.gridColumns(app, content)
	local gap = theme:space(16)
	local cardWidth = math.max(120, math.floor((content - gap * (columns - 1)) / columns))
	local cardHeight = albumCard.height(app, cardWidth)
	local topCount = math.min(6, #artist.tracks)
	local topHeight = theme:px(24) + topCount * theme:px(48)
	local albumRows = math.ceil(#artist.albums / columns)
	local rowHeight = cardHeight + gap
	local albumsHeight = theme:px(24) + albumRows * rowHeight
	local albumStart = heroHeight + topHeight + theme:space(144)
	local contentHeight = albumStart + albumsHeight
	local viewport = metrics.viewportHeight(app, window.width, window.height)
	app.services.scroll:setLimit(app:pageKey(), metrics.pageScrollLimit(app, window, contentHeight))
	local scroll = app.services.scroll:offset(app:pageKey())
	local first, last, sliceTop = app.services.scroll.slices(
		#artist.albums,
		columns,
		rowHeight,
		math.max(0, scroll - albumStart),
		viewport
	)

	local s = pageStyles(theme, content, heroSize, heroHeight, albumsHeight, contentHeight, topHeight)
	if s.topCount ~= #artist.tracks or s.albumCount ~= #artist.albums then
		s.topCount, s.albumCount = #artist.tracks, #artist.albums
		s.counts = format.count(#artist.albums, "album") .. " · " .. format.count(#artist.tracks, "track")
	end

	local action = playAction(artist)
	heroCoverProps.album, heroCoverProps.size, heroCoverProps.radius = album, heroSize, theme:radius("lg")
	local art
	if album ~= nil then
		art = cover.view(app, heroCoverProps --[[@as beat.components.CoverProps]])
	else
		art = div():style(s.art)
	end
	local hero = div():style(s.hero):children(
		art,
		div()
			:style(s.nameColumn)
			:children(
				text("ARTIST"):style(s.label),
				text(artist.name):style(s.name),
				text(assert(s.counts)):style(s.count),
				div()
					:style(s.actionsRow)
					:children(
						div()
							:style(s.play):onClick(action)
							:children(ui.icon(ctx, { name = "play", size = theme:px(18), colour = theme.accentInk })),
						text("Play all"):style(s.playLabel):onClick(action)
					)
			)
	)

	local current = app.services.playback:current()
	local playing = app.services.playback.player:isPlaying()
	local loading = app.services.playback:isLoading()
	local top = {}
	for index, track in ipairs(artist.tracks) do
		if index > 6 then break end
		local props = topRow(track, artist.id)
		props.index = index
		props.current = current?.id == track.id
		props.playing = playing
		props.loading = props.current and loading
		props.width = content
		top[#top + 1] = trackRow.view(app, props)
	end

	local rows = {}
	if sliceTop > 0 then
		local pad = styles.of(theme, "artistSlicePad", sliceTop) --[[@as { style: wonderland.StyleBuilder? }]]
		if pad.style == nil then pad.style = sty():h(sliceTop) end
		rows[#rows + 1] = div():style(assert(pad.style))
	end
	local row = {}
	for at = first, last do
		local release = artist.albums[at]
		if release ~= nil then
			row[#row + 1] = albumCard.view(app, release, cardWidth, ctx)
		end
		if #row == columns or at == last then
			rows[#rows + 1] = div():style(s.albumRow):children(row)
			row = {}
		end
	end

	return div()
		:style(s.column)
		:children(
			hero,
			ui.section(ctx, { title = "Top tracks" }),
			div():style(s.topBox):children(top),
			ui.section(ctx, { title = "Albums" }),
			div():style(s.albumColumn):children(rows)
		)
end

return artistPage
