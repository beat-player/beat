-- The artist screen: a hero of their first cover, their top tracks, and every album.
local wonderland = require("wonderland")
local names = require("beat.music.names")
local ui = require("beat-ui")
local render = require("beat.app.components.ui")
local metrics = require("beat.app.components.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

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
	local artist = app.services.library.current ~= nil and app.services.library.current:artist(page.id) or nil
	if artist == nil then
		return render.empty(app, "Artist not found", "The scan no longer has them.", "Library",
		{ type = "navigate", page = { kind = "library"}})
	end
	---@cast artist beat.Artist
	local theme = app.services.appearance.theme
	local content = metrics.contentWidth(app, window.width)
	local heroSize = math.min(theme:px(160), math.floor(content * 0.24))
	local heroHeight = heroSize + theme:space(24)
	local album = artist.albums[1]
	local columns = metrics.gridColumns(content)
	local gap = theme:space(16)
	local cardWidth = math.max(120, math.floor((content - gap * (columns - 1)) / columns))
	local cardHeight = render.albumCardHeight(app, cardWidth)
	local topCount = math.min(6, #artist.tracks)
	local topHeight = theme:px(24) + topCount * theme:px(48)
	local albumRows = math.ceil(#artist.albums / columns)
	local rowHeight = cardHeight + gap
	local albumsHeight = theme:px(24) + albumRows * rowHeight
	local albumStart = heroHeight + topHeight + theme:space(144)
	local contentHeight = albumStart + albumsHeight
	local viewport = metrics.viewportHeight(app, window.width, window.height)
	app.services.scroll:setLimit(app:pageKey(),
	math.max(0, contentHeight - viewport))
	local scroll = app.services.scroll:offset(app:pageKey())
	local first, last, sliceTop = app.services.scroll.slices(#artist.albums, columns, rowHeight,
	math.max(0, scroll - albumStart), viewport)
	---@cast first number
	---@cast last number
	---@cast sliceTop number

	local hero = div():style(sty():row():wrel(1.0):h(heroHeight):pad(0, 0, 0, 0):gap(theme:space(24))
	:align("center")):children({
	album ~= nil and render.cover(app, album, heroSize, theme:radius("lg"), true)
	or div():style(sty():size(heroSize, heroSize):radius(theme:radius("lg")):bg(theme:color("elevated"))),
	div():style(sty():column():h(heroHeight):justify("center"):gap(theme:px(8))):children({
	text("ARTIST"):style(theme:s():text(theme:type("xs")):weight("bold"):fg(theme:color("muted"))),
	text(artist.name):style(theme:s():text(theme:type("hero")):weight("bold")
	:fg(theme:color("text"))),
	text(names.count(#artist.albums, "album") .. " · " .. names.count(#artist.tracks, "track")):style(
	theme:s():text(theme:type("sm")):fg(theme:color("muted"))
	),
	div():style(sty():row():h(theme:px(38)):gap(theme:px(10)):align("center")):children({
	div():style(sty():size(theme:px(38), theme:px(38)):radius(theme:radius("full"))
	:bg(theme:color("accent")):align("center"):justify("center"))
	:onClick({ type = "playArtist", id = artist.id})
	:children(ui.icons.element("play", theme:px(18), theme.accentInk)),
	text("Play all"):style(theme:s():text(theme:type("sm")):weight("semibold")
	:fg(theme:color("text"))):onClick({ type = "playArtist", id = artist.id}),
	}),
	}),
	})

	local top = {}
	for index, track in ipairs(artist.tracks) do
			if index > 6 then break end
			top[#top + 1] = render.trackRow(app, track, index,
			app.services.playback:current() ~= nil and app.services.playback:current().id == track.id, app.services.playback.player:isPlaying(),
			{ type = "playTrack", trackId = track.id, artistId = artist.id}, content, true)
		end

	local rows = {}
	if sliceTop > 0 then rows[#rows + 1] = div():style(sty():h(sliceTop)) end
	local row = {}
	for at = first, last do
			local release = artist.albums[at]
			if release ~= nil then
				row[#row + 1] = render.albumCard(app, release, cardWidth,
				{ type = "navigate", page = { kind = "album", id = release.id}},
				{ type = "playAlbum", id = release.id})
			end
			if #row == columns or at == last then
				rows[#rows + 1] = div():style(sty():row():wrel(1.0):h("auto"):gap(gap)):children(row)
				row = {}
			end
		end

	return div():style(sty():column():wrel(1.0):h(contentHeight):gap(theme:space(24))):children({
	hero,
	render.section(app, "Top tracks"),
	div():style(sty():column():wrel(1.0):h(topHeight):gap(2)):children(top),
	render.section(app, "Albums"),
	div():style(sty():column():wrel(1.0):h(albumsHeight):gap(gap)):children(rows),
	})
end

return artistPage
