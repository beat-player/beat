-- The first screen: what is playing, what was just added, and a way into the library while it is
-- still being read.
local wonderland = require("wonderland")
local path = require("path")
local format = require("beat.app.components.format")
local render = require("beat.app.components.ui")
local metrics = require("beat.app.components.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@type beat.PageSurface
local home = {}

-- Home is where Escape stops: there is nothing behind it to go back to.
function home.update(_, _, message)
	return message.type == "escape"
end

function home.view(app, page, window)
	local theme = app.services.appearance.theme
	local library = app.services.library.current
	local scan = app.services.scan
	if library == nil or (scan.job ~= nil and #library.tracks == 0) then
		if scan.job ~= nil then
			local progress = scan.job:progress()
			local current = progress.current
			local currentName = nil
			if type(current) == "string" then currentName = path.basename(current) end
			local scanning = {
			render.equalizer(app, true),
			text(progress.phase == "enumerate" and "Finding your music" or "Reading your music"):style(
			theme:s():text(theme:type("xl")):weight("bold"):fg(theme:color("text"))
			),
			text(format.count(progress.tracks, "track") .. " · " .. progress.inspected .. " / "
			.. progress.files):style(theme:s():text(theme:type("sm")):fg(theme:color("muted"))),
			render.meter(theme:px(420), theme:px(4), render.scanFraction(progress),
			theme:color("text", 0.1), theme:color("accent")),
			}
			if currentName ~= nil then
				scanning[#scanning + 1] = text(tostring(currentName)):style(
				theme:s():w(theme:px(520)):text(theme:type("xs")):fg(theme:color("faint")):ellipsis()
				)
			end
			if progress.skipped > 0 then
				scanning[#scanning + 1] = text(format.count(progress.skipped, "file") .. " skipped"):style(
				theme:s():text(theme:type("xs")):fg(theme:color("danger"))
				)
			end
			scanning[#scanning + 1] = render.button(app, "Cancel scan", { type = "cancelScan"},
			{ height = theme:px(30), width = theme:px(110)})
			return div():style(sty():fill():column():align("center"):justify("center")
			:gap(theme:px(14))):children(scanning)
		end

		return render.empty(app, "Your library is empty", "Choose a folder and every track in it appears here.",
		"Choose a folder", { type = "chooseFolder"})
	end

	local content = metrics.contentWidth(app, window.width)
	local columns = metrics.gridColumns(content)
	local gap = theme:space(16)
	local cardWidth = math.max(120, math.floor((content - gap * (columns - 1)) / columns))
	local recent = library:recentlyAdded(columns)

	local cardHeight = render.albumCardHeight(app, cardWidth)
	local sectionHeight = theme:px(24)

	local function cardRow(albums, limit)
		local children = {}
		for at, album in ipairs(albums) do
				if limit ~= nil and at > limit then break end
				children[#children + 1] = render.albumCard(app, album, cardWidth,
				{ type = "navigate", page = { kind = "album", id = album.id}},
				{ type = "playAlbum", id = album.id})
			end
		return div():style(sty():row():wrel(1.0):h(cardHeight):gap(gap)):children(children)
	end

	local listened = app.services.collections.taxonomy:recentAlbums(library, columns)
	local children = {}
	local height = 0
	if #listened > 0 then
		children[#children + 1] = render.section(app, "Recently listened")
		children[#children + 1] = cardRow(listened)
		height = height + sectionHeight + cardHeight + gap * 2
	end
	children[#children + 1] = render.section(app, "Recently added")
	children[#children + 1] = cardRow(recent)
	children[#children + 1] = render.section(app, "Your albums")
	children[#children + 1] = cardRow(library.albums, columns)
	height = height + sectionHeight + cardHeight + sectionHeight + cardHeight + gap * 4

	if #library.artists > 0 then
		local artists = {}
		for at = 1, math.min(columns, #library.artists) do artists[#artists + 1] = library.artists[at] end
		local cards = {}
		for _, artist in ipairs(artists) do
				local album = artist.albums[1]
				cards[#cards + 1] = div()
				:style(sty():w(cardWidth):h(cardHeight):column():gap(theme:px(6)))
				:hover(sty():w(cardWidth):h(cardHeight):column():gap(theme:px(6)):bright(1.08))
				:onClick({ type = "navigate", page = { kind = "artist", id = artist.id}})
				:children({
				album ~= nil and render.cover(app, album, cardWidth, theme:radius("full"))
				or div():style(sty():size(cardWidth, cardWidth):radius(theme:radius("full"))
				:bg(theme:color("elevated"))),
				text(artist.name):style(theme:s():w(cardWidth):text(theme:type("base")):weight("semibold")
				:fg(theme:color("text")):ellipsis()),
				text("Artist"):style(theme:s():text(theme:type("sm")):fg(theme:color("muted"))),
				})
			end
		children[#children + 1] = render.section(app, "Artists")
		children[#children + 1] = div():style(sty():row():wrel(1.0):h(cardHeight):gap(gap)):children(cards)
		height = height + sectionHeight + cardHeight + gap * 2
	end

	return div():style(sty():column():wrel(1.0):h(height):gap(gap)):children(children)
end

return home
