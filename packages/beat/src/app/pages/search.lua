-- Search is one field over artists, albums and tracks; with nothing typed it shows what was just
-- added, narrowed by whichever tags are selected.
local wonderland = require("wonderland")
local render = require("beat.app.components.ui")
local metrics = require("beat.app.components.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@type beat.PageSurface
local searchPage = {}

function searchPage.update(app, page, message)
	-- Escape clears what was typed before it leaves the page. The field belongs to the search
	-- service; the page only decides that Escape means the field first.
	local search = app.services.search
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
	local columns = width >= 900 and 6 or (width >= 600 and 4 or 3)
	local pills = render.tagPills(app, tags, search.tagFilter, function(tag)
		return { type = "toggleTagFilter", id = tag.id}
	end, width, columns)
	if pills == nil then return nil, 0 end

	local headerActions = {}
	if next(search.tagFilter) ~= nil then
		headerActions[#headerActions + 1] = text("All"):style(theme:s():text(theme:type("xs"))
		:weight("semibold"):fg(search.match == "all" and theme:color("accent")
		or theme:color("muted"))):onClick({ type = "tagFilterMatch", value = "all"})
		headerActions[#headerActions + 1] = text("Any"):style(theme:s():text(theme:type("xs"))
		:weight("semibold"):fg(search.match == "any" and theme:color("accent")
		or theme:color("muted"))):onClick({ type = "tagFilterMatch", value = "any"})
		headerActions[#headerActions + 1] = text("Clear"):style(theme:s():text(theme:type("xs"))
		:weight("semibold"):fg(theme:color("accent"))):onClick({ type = "clearTagFilter"})
	end
	local headerChildren = {
	text("Filter by tag"):style(theme:s():wrel(1.0):text(theme:type("xs")):weight("bold")
	:fg(theme:color("muted"))),
	div():style(sty():row():w(theme:px(120)):gap(theme:px(8)):align("center")
	:justify("end")):children(headerActions),
	}

	local rows = math.ceil(#tags / columns)
	local height = theme:px(18) + theme:px(8) + rows * theme:px(28)
	+math.max(0, rows - 1) * theme:px(8) + theme:px(4)
	return div():style(sty():column():wrel(1.0):h(height):gap(theme:px(8))):children({
	div():style(sty():row():wrel(1.0):h(theme:px(18)):justify("space-between"):align("center")):children(
	headerChildren),
	pills,
	}), height
end

function searchPage.view(app, page, window)
	local theme = app.services.appearance.theme
	local search = app.services.search
	local library = app.services.library.current
	if library == nil then
		return render.empty(app, "Search your library", "Choose a folder first.", "Choose a folder",
		{ type = "chooseFolder"})
	end

	local content = metrics.contentWidth(app, window.width)
	local filter, filterHeight = searchTagFilter(app, content)
	local columns = metrics.gridColumns(content)
	local gap = theme:space(16)
	local cardWidth = math.max(120, math.floor((content - gap * (columns - 1)) / columns))
	local cardHeight = render.albumCardHeight(app, cardWidth)

	if search.query == "" then
		local recent = library:recentlyAdded(columns)
		local filterIds = search:filterIds()
		if #filterIds > 0 then
			local taxonomy = app.services.collections.taxonomy
			local matching = {}
			for _, album in ipairs(recent) do
				local keep = false
				for _, track in ipairs(album.tracks) do
					if taxonomy:matches(track.path, filterIds, search.match) then keep = true; break end
						end
					if keep then matching[#matching + 1] = album end
				end
			recent = matching
		end
		local cards = {}
		for _, album in ipairs(recent) do
				---@cast album beat.Album
				cards[#cards + 1] = render.albumCard(app, album, cardWidth,
				{ type = "navigate", page = { kind = "album", id = album.id}},
				{ type = "playAlbum", id = album.id})
			end
		return div():style(sty():column():wrel(1.0):h(cardHeight + theme:px(150)):gap(gap)):children({
		text("Search your library"):style(theme:s():text(theme:type("xxl")):weight("bold")
		:fg(theme:color("text"))),
		text("Artists, albums and tracks are all one field."):style(
		theme:s():text(theme:type("sm")):fg(theme:color("muted"))
		),
		render.section(app, "Recently added"),
		div():style(sty():row():wrel(1.0):h(cardHeight):gap(gap)):children(cards),
		})
	end

	local albums, artists, tracks = search:results()
	local albumLimit = math.min(#albums, columns * 2)
	local artistLimit = math.min(#artists, 10)
	local trackLimit = math.min(#tracks, 100)
	local albumRows = math.ceil(albumLimit / columns)
	local rowGap = theme:space(16)
	local sectionGap = theme:space(16)
	local sectionHeight = theme:px(24)
	local height = theme:px(40) + filterHeight
	if albumLimit > 0 then
		height = height + sectionGap + sectionHeight + sectionGap + albumRows * cardHeight
		+math.max(0, albumRows - 1) * rowGap
	end
	if artistLimit > 0 then
		height = height + sectionGap + sectionHeight + sectionGap + artistLimit * theme:px(56)
	end
	if trackLimit > 0 then
		height = height + sectionGap + sectionHeight + sectionGap + trackLimit * theme:px(48)
	end

	local children = {
	text("Results for \"" .. search.query .. "\""):style(theme:s():wrel(1.0):text(theme:type("xxl"))
	:weight("bold"):fg(theme:color("text")):ellipsis()),
	}
	if filter ~= nil then children[#children + 1] = filter end

	if albumLimit > 0 then
		children[#children + 1] = render.section(app, "Albums",
		#albums > albumLimit and { type = "navigate",
		page = { kind = "searchAll", category = "albums"}} or nil)
		for rowAt = 1, albumRows do
				local row = {}
				for columnAt = 1, columns do
						local at = (rowAt - 1) * columns + columnAt
						local album = albums[at]
						if album ~= nil and at <= albumLimit then
							row[#row + 1] = render.albumCard(app, album, cardWidth,
							{ type = "navigate", page = { kind = "album", id = album.id}},
							{ type = "playAlbum", id = album.id})
						end
					end
				children[#children + 1] = div():style(sty():row():wrel(1.0):h(cardHeight):gap(gap)):children(row)
			end
	end

	if artistLimit > 0 then
		children[#children + 1] = render.section(app, "Artists",
		#artists > artistLimit and { type = "navigate",
		page = { kind = "searchAll", category = "artists"}} or nil)
		for at, artist in ipairs(artists) do
				if at > artistLimit then break end
				children[#children + 1] = div()
				:style(sty():row():h(theme:px(56)):gap(theme:px(12)):align("center"):radius(theme:radius("sm")))
				:hover(sty():row():h(theme:px(56)):gap(theme:px(12)):align("center"):radius(theme:radius("sm"))
				:bg(theme:color("hover")))
				:onClick({ type = "navigate", page = { kind = "artist", id = artist.id}})
				:children({
				artist.albums[1] ~= nil and render.cover(app, artist.albums[1], theme:px(44),
				theme:radius("full")) or div():style(sty():size(theme:px(44), theme:px(44))
				:radius(theme:radius("full")):bg(theme:color("elevated"))),
				text(artist.name):style(theme:s():text(theme:type("base")):weight("semibold")
				:fg(theme:color("text"))),
				})
			end
	end

	if trackLimit > 0 then
		children[#children + 1] = render.section(app, "Tracks",
		#tracks > trackLimit and { type = "navigate",
		page = { kind = "searchAll", category = "tracks"}} or nil)
		for at, track in ipairs(tracks) do
				if at > trackLimit then break end
				children[#children + 1] = render.trackRow(app, track, at,
				app.services.playback:current() ~= nil and app.services.playback:current().id == track.id, app.services.playback.player:isPlaying(),
				{ type = "playTrack", trackId = track.id}, content, true)
			end
	end

	if #albums + #artists + #tracks == 0 then
		height = height + theme:px(300) + sectionGap
		children[#children + 1] = div():style(sty():wrel(1.0):h(theme:px(300))):children({
		render.empty(app, "No results", "Try a different artist, album or title.",
		"Clear search", { type = "clearSearch"}),
		})
	end

	return div():style(sty():column():wrel(1.0):h(height + theme:space(24)):gap(theme:space(16))):children(children)
end

return searchPage
