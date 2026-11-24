-- The first screen: what is playing, what was just added, and a way into the library while it is
-- still being read.
local wonderland = require("wonderland")
local path = require("path")
local ui = require("beat-ui")
local format = require("beat.app.components.helpers.format")
local albumCard = require("beat.app.components.album_card")
local cover = require("beat.app.components.cover")
local playingBars = require("beat.app.components.playing_bars")
local metrics = require("beat.app.components.helpers.metrics")
local styles = require("beat.app.components.helpers.styles")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

-- The bar a scan fills: the only one home draws, so its numbers are kept here and the draw that
-- reads them is made once. A function declared in the view is one that closes an upvalue on every
-- frame the bar is in.
local meterState = { value = 0, trackColour = "", fillColour = "", radius = 0 }

---@param canvas wonderland.Canvas
local function drawMeter(canvas)
	canvas:rect(0, 0, canvas.width, canvas.height, meterState.trackColour, meterState.radius)
	canvas:rect(0, 0, canvas.width * meterState.value, canvas.height, meterState.fillColour, meterState.radius)
end

--- A bar whose fill follows a value, drawn to a canvas: the fill is a shape, not a style.
---@param width number
---@param height number
---@param fraction number
---@param trackColour string
---@param fillColour string
local function meter(width, height, fraction, trackColour, fillColour)
	meterState.value = math.max(0, math.min(1, fraction))
	meterState.trackColour, meterState.fillColour, meterState.radius = trackColour, fillColour, height / 2
	return div():style(sty():w(width):h(height)):canvas(drawMeter)
end

-- The headings, which say the same thing on every frame.
local RECENTLY_LISTENED = { title = "Recently listened" }
local RECENTLY_ADDED = { title = "Recently added" }
local YOUR_ALBUMS = { title = "Your albums" }
local ARTISTS = { title = "Artists" }

--- The albums heard lately, kept against the taxonomy's revision and the library they were read
--- from: home asks every frame, and answering means walking every album that has a metric and
--- sorting them. A listen is the only thing that changes the answer, and that bumps the revision.
---@type { revision: number, library: beat.Library, limit: number, albums: beat.Album[] }?
local listenedCache

---@param app beat.App
---@param library beat.Library
---@param limit number
local function listenedAlbums(app, library, limit)
	local taxonomy = app.services.collections.taxonomy
	local kept = listenedCache
	if kept == nil or kept.revision ~= taxonomy.revision or kept.library ~= library or kept.limit ~= limit then
		kept = { revision = taxonomy.revision, library = library, limit = limit, albums = taxonomy:recentAlbums(library, limit) }
		listenedCache = kept
	end
	return kept.albums
end

---@param app beat.App
---@param albums beat.Album[]
---@param limit number?
---@param rowBox wonderland.StyleBuilder
---@param cardWidth number
---@param ctx beat.ui.Context
local function cardRow(app, albums, limit, rowBox, cardWidth, ctx)
	-- A count first, then a plain numeric walk: the iterator and the early break inside this loop
	-- were what left it interpreted at the root of the home shelf's trace.
	local count = #albums
	if limit ~= nil and count > limit then count = limit end
	local children = {}
	for at = 1, count do
		children[at] = albumCard.view(app, albums[at], cardWidth, ctx)
	end
	return div():style(rowBox):children(children)
end

-- The props an artist's round cover is built from, written again each time: the cover reads them
-- and keeps nothing, and the shelf is built on every frame it is scrolled.
---@type table<string, any>
local artistCoverProps = { radius = 0 }

-- What a press on an artist's card sends, made once per artist: a shelf is built again on every
-- frame it is scrolled, and the message names the artist rather than the frame.
---@type table<beat.Artist, table>
local artistActions = setmetatable({}, { __mode = "k" })

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

---@class beat.components.HomeArtistStyles
---@field card wonderland.StyleBuilder
---@field hover wonderland.StyleBuilder
---@field art wonderland.StyleBuilder
---@field name wonderland.StyleBuilder
---@field role wonderland.StyleBuilder

---@type beat.PageSurface
local home = {}

-- Home is where Escape stops: there is nothing behind it to go back to.
---@param message beat.Message
function home.update(_, _, message)
	return message.type == "escape"
end

---@param app beat.App
---@param page beat.PageInstance
---@param window wonderland.RenderWindow
function home.view(app, page, window)
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local library = app.services.library.current
	local scan = app.services.scan
	if library == nil or (scan.job ~= nil and #library.tracks == 0) then
		if scan.job ~= nil then
			local progress = scan.job:progress()
			local current = progress.current
			local currentName = nil
			if type(current) == "string" then currentName = path.basename(current) end
			local scanning = {
				playingBars.view(app, { playing = true }),
				text(progress.phase == "enumerate" ? "Finding your music" : "Reading your music")
					:style(theme:s():text(theme:type("xl")):weight("bold"):fg(theme:color("text"))),
				text(format.count(progress.tracks, "track") .. " · " .. progress.inspected .. " / " .. progress.files)
					:style(theme:s():text(theme:type("sm")):fg(theme:color("muted"))),
				meter(theme:px(420), theme:px(4), scan:fraction(), theme:color("text", 0.1), theme:color("accent"))
			}
			if currentName ~= nil then
				scanning[#scanning + 1] = text(tostring(currentName))
					:style(theme:s():w(theme:px(520)):text(theme:type("xs")):fg(theme:color("faint")):ellipsis())
			end
			if progress.skipped > 0 then
				scanning[#scanning + 1] = text(format.count(progress.skipped, "file") .. " skipped")
					:style(theme:s():text(theme:type("xs")):fg(theme:color("danger")))
			end
			scanning[#scanning + 1] = ui.button(
				ctx,
				{ label = "Cancel scan", onClick = { type = "cancelScan" }, height = theme:px(30), width = theme:px(110) }
			)
			return div():style(sty():fill():column():align("center"):justify("center"):gap(theme:px(14))):children(scanning)
		end

		return ui.emptyState(
			ctx,
			{
				title = "Your library is empty",
				copy = "Choose a folder and every track in it appears here.",
				actionLabel = "Choose a folder",
				action = { type = "chooseFolder" }
			}
		)
	end

	local content = metrics.contentWidth(app, window.width)
	local columns = metrics.gridColumns(app, content)
	local gap = theme:space(16)
	local cardWidth = math.max(120, math.floor((content - gap * (columns - 1)) / columns))
	local recent = library:recentlyAdded(columns)

	local cardHeight = albumCard.height(app, cardWidth)
	local sectionHeight = theme:px(24)

	-- The shelf's own boxes, which depend on the card and the gap: the same for every frame of a
	-- layout, so they are kept where the theme keeps what it built rather than made per frame.
	local shelf = styles.of(theme, "homeShelf", cardWidth) --[[@as { row: wonderland.StyleBuilder }]]
	local rowBox = shelf.row
	if rowBox == nil then
		rowBox = sty():row():wrel(1.0):h(cardHeight):gap(gap)
		shelf.row = rowBox
	end

	local listened = listenedAlbums(app, library, columns)
	local children = {}
	local height = 0
	if #listened > 0 then
		children[#children + 1] = ui.section(ctx, RECENTLY_LISTENED)
		children[#children + 1] = cardRow(app, listened, nil, rowBox, cardWidth, ctx)
		height = height + sectionHeight + cardHeight + gap * 2
	end
	children[#children + 1] = ui.section(ctx, RECENTLY_ADDED)
	children[#children + 1] = cardRow(app, recent, nil, rowBox, cardWidth, ctx)
	children[#children + 1] = ui.section(ctx, YOUR_ALBUMS)
	children[#children + 1] = cardRow(app, library.albums, columns, rowBox, cardWidth, ctx)
	height = height + sectionHeight + cardHeight + sectionHeight + cardHeight + gap * 4

	if #library.artists > 0 then
		local artist = styles.of(theme, "homeArtist", cardWidth) --[[@as beat.components.HomeArtistStyles]]
		if artist.card == nil then
			artist.card = sty():w(cardWidth):h(cardHeight):column():gap(theme:px(6))
			artist.hover = sty():w(cardWidth):h(cardHeight):column():gap(theme:px(6)):bright(1.08)
			artist.art = sty():size(cardWidth, cardWidth):radius(theme:radius("full")):bg(theme:color("elevated"))
			artist.name = theme:s():w(cardWidth):text(theme:type("base")):weight("semibold"):fg(theme:color("text")):ellipsis()
			artist.role = theme:s():text(theme:type("sm")):fg(theme:color("muted"))
		end
		local cards = {}
		local radius = theme:radius("full")
		for at = 1, math.min(columns, #library.artists) do
			local entry = library.artists[at]
			local album = entry.albums[1]
			local art
			if album ~= nil then
				artistCoverProps.album, artistCoverProps.size, artistCoverProps.radius = album, cardWidth, radius
				art = cover.view(app, artistCoverProps --[[@as beat.components.CoverProps]])
			else
				art = div():style(artist.art)
			end
			cards[#cards + 1] = div()
				:style(artist.card):hover(artist.hover)
				:onClick(artistAction(entry))
				:children(art, text(entry.name):style(artist.name), text("Artist"):style(artist.role))
		end
		children[#children + 1] = ui.section(ctx, ARTISTS)
		children[#children + 1] = div():style(rowBox):children(cards)
		height = height + sectionHeight + cardHeight + gap * 2
	end

	local column = styles.of(theme, "homeColumn", height) --[[@as { style: wonderland.StyleBuilder }]]
	if column.style == nil then column.style = sty():column():wrel(1.0):h(height):gap(gap) end
	return div():style(column.style):children(children)
end

return home
