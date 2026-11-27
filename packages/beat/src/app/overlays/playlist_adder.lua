-- The panel that fills a playlist by hand, opened from the playlist's own +.
--
-- Albums and tracks are the two things a manual list takes, and they are different kinds of row:
-- an album adds every track on it, a track adds itself. They are one list at a time behind a
-- segmented choice, a search over both, and both lists are windowed like every other long list in
-- the app so a library of thousands costs a handful of rows a frame.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local cover = require("beat.app.components.cover")
local format = require("beat.app.components.helpers.format")
local metrics = require("beat.app.components.helpers.metrics")
local searchField = require("beat.app.components.search_field")
local settingsList = require("beat.app.components.settings_list")
local styleCache = require("beat.app.components.helpers.styles")
local names = require("beat.music.names")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local SCROLL_KEY = "playlistAdder"
local ROW_NAME = "playlistAdderRow"
local TRAIL_NAME = "playlistAdderTrail"

---@class beat.PlaylistAdderState
---@field playlistId number
---@field query string
---@field mode "albums"|"tracks"
---@field scrollMax number # The list's own limit, read by the one scroll handler this panel makes
---@field scrollHandler fun(by: number, to: number?): table
---@field spacers table<number, wonderland.StyleBuilder>? # The list's blank runs, by height
---@field countAt number? # The count the section's label was made for
---@field countMode string? # And the section it names
---@field countLabel string? # That label

---@class beat.PlaylistAdderStyles
---@field rowHeight number
---@field rowPadding number
---@field rowGap number
---@field coverSize number
---@field trailSize number
---@field trailIcon number
---@field names wonderland.StyleBuilder
---@field title wonderland.StyleBuilder
---@field subtitle wonderland.StyleBuilder
---@field fallbackCover wonderland.StyleBuilder
---@field trailBase wonderland.StyleBuilder
---@field trailHover wonderland.StyleBuilder
---@field trailDone wonderland.StyleBuilder
---@field trailDoneHover wonderland.StyleBuilder
---@field headerTitle wonderland.StyleBuilder
---@field section wonderland.StyleBuilder
---@field sectionTitle wonderland.StyleBuilder
---@field sectionCount wonderland.StyleBuilder
---@field emptyBlock wonderland.StyleBuilder
---@field emptyIcon wonderland.StyleBuilder
---@field emptyTitle wonderland.StyleBuilder
---@field emptyCopy wonderland.StyleBuilder

-- The row, the mark that ends it and the two lines between them depend on the theme and the width
-- the rows get, not on the frame. Both widths a panel can have -- the content between its padding,
-- and the little less the scroll bar leaves -- are kept, because a list that gains a bar asks for
-- the second one and keeps asking for it on every frame after.
---@type table<beat.Theme, table<number, beat.PlaylistAdderStyles>>
local stylesByTheme = setmetatable({}, { __mode = "k" })

---@param theme beat.Theme
---@param width number # The width of one row
---@return beat.PlaylistAdderStyles
local function adderStyles(theme, width)
	local byWidth = stylesByTheme[theme]
	if byWidth == nil then
		byWidth = {}
		stylesByTheme[theme] = byWidth
	end
	local styles = byWidth[width]
	if styles == nil then
		local rowHeight = theme:px(54)
		local rowPadding = theme:px(8)
		local rowGap = theme:px(10)
		local coverSize = theme:px(40)
		local trailSize = theme:px(28)
		local textWidth = math.max(theme:px(1), width - rowPadding * 2 - coverSize - trailSize - rowGap * 2)
		local radius = theme:radius("full")
		local accent = theme:color("accent")
		styles = {
			rowHeight = rowHeight,
			rowPadding = rowPadding,
			rowGap = rowGap,
			coverSize = coverSize,
			trailSize = trailSize,
			trailIcon = theme:px(16),
			names = sty():column():w(textWidth):gap(theme:px(1)),
			title = theme:s():w(textWidth):text(theme:type("sm")):weight("semibold"):fg(theme:color("text")):ellipsis(),
			subtitle = theme:s():w(textWidth):text(theme:type("xs")):fg(theme:color("muted")):ellipsis(),
			fallbackCover = sty()
				:size(coverSize, coverSize):radius(theme:radius("sm")):bg(theme:color("elevated")):row():align("center")
				:justify("center"),
			trailBase = sty()
				:size(trailSize, trailSize):radius(radius):bg(theme:color("accent", 0.14)):row():align("center")
				:justify("center"),
			trailHover = sty()
				:size(trailSize, trailSize):radius(radius):bg(theme:color("accent", 0.24)):row():align("center")
				:justify("center"),
			trailDone = sty()
				:size(trailSize, trailSize):radius(radius):bg(accent):row():align("center"):justify("center"),
			trailDoneHover = sty()
				:size(trailSize, trailSize):radius(radius):bg(accent):row():align("center"):justify("center"),
			headerTitle = theme:s()
				:w(width - theme:px(36)):text(theme:type("lg")):weight("bold"):fg(theme:color("text")):ellipsis(),
			section = sty():row():w(width):h(theme:px(20)):gap(rowGap):align("center"):justify("space-between"),
			sectionTitle = theme:s():text(theme:type("xs")):weight("semibold"):fg(theme:color("muted")),
			sectionCount = theme:s():text(theme:type("xs")):fg(theme:color("faint")),
			emptyBlock = sty()
				:column():w(width):h(theme:px(176)):align("center"):justify("center"):gap(theme:px(8)),
			emptyIcon = sty()
				:size(theme:px(48), theme:px(48)):radius(radius):bg(theme:color("accent", 0.14)):row():align("center")
				:justify("center"),
			emptyTitle = theme:s():text(theme:type("md")):weight("semibold"):fg(theme:color("text")),
			emptyCopy = theme:s():text(theme:type("sm")):fg(theme:color("muted"))
		}
		byWidth[width] = styles
	end
	return styles
end

-- The messages the panel's controls send. The segmented choice's options are two fixed tables, so
-- opening the panel again does not add a table to the settings component's style cache, and the
-- choice's labels stay the ones its boxes were measured for.
local MODE_ALBUMS = { type = "playlistAdderMode", value = "albums" }
local MODE_TRACKS = { type = "playlistAdderMode", value = "tracks" }
local ALBUM_OPTIONS = {
	{ label = "Albums", selected = true, message = MODE_ALBUMS },
	{ label = "Tracks", selected = false, message = MODE_TRACKS }
}
local TRACK_OPTIONS = {
	{ label = "Albums", selected = false, message = MODE_ALBUMS },
	{ label = "Tracks", selected = true, message = MODE_TRACKS }
}

-- One message per album or track, kept on the record: a row is built again on every frame it is
-- scrolled, and a message is the same message for the whole life of the item it names.
---@type table<beat.Album, table>
local albumAdds = setmetatable({}, { __mode = "k" })
---@type table<beat.Album, table>
local albumRemoves = setmetatable({}, { __mode = "k" })
---@type table<beat.Track, table>
local trackAdds = setmetatable({}, { __mode = "k" })
---@type table<beat.Track, table>
local trackRemoves = setmetatable({}, { __mode = "k" })

---@param album beat.Album
---@return table
local function albumAdd(album)
	local message = albumAdds[album]
	if message == nil then
		message = { type = "playlistAddAlbum", id = album.id }
		albumAdds[album] = message
	end
	return message
end

---@param album beat.Album
---@return table
local function albumRemove(album)
	local message = albumRemoves[album]
	if message == nil then
		message = { type = "playlistRemoveAlbum", id = album.id }
		albumRemoves[album] = message
	end
	return message
end

---@param track beat.Track
---@return table
local function trackAdd(track)
	local message = trackAdds[track]
	if message == nil then
		message = { type = "playlistAddTrack", id = track.id }
		trackAdds[track] = message
	end
	return message
end

---@param track beat.Track
---@return table
local function trackRemove(track)
	local message = trackRemoves[track]
	if message == nil then
		message = { type = "playlistAdderRemoveTrack", id = track.id }
		trackRemoves[track] = message
	end
	return message
end

-- What a row says about its item, kept on the item: a windowed list builds the same rows again on
-- every frame it is scrolled, and a row's key and its second line are the same for the life of the
-- track or album they name. The track objects a metadata write replaces take their entries with
-- them; the taxonomy's own key for a track is already kept by `names`.
---@type table<beat.Album, string>
local albumRowKeys = setmetatable({}, { __mode = "k" })
---@type table<beat.Track, string>
local trackRowKeys = setmetatable({}, { __mode = "k" })
---@type table<beat.Track, string>
local trackSubtitles = setmetatable({}, { __mode = "k" })

---@param album beat.Album
---@return string
local function albumRowKey(album)
	local key = albumRowKeys[album]
	if key == nil then
		key = "album:" .. album.id
		albumRowKeys[album] = key
	end
	return key
end

---@param track beat.Track
---@return string
local function trackRowKey(track)
	local key = trackRowKeys[track]
	if key == nil then
		key = "track:" .. track.id
		trackRowKeys[track] = key
	end
	return key
end

--- The artist and, where it adds something, the album. A rescan hands the panel new track objects,
--- so the line follows the tags without a revision to invalidate it.
---@param track beat.Track
---@return string
local function trackSubtitle(track)
	local subtitle = trackSubtitles[track]
	if subtitle == nil then
		subtitle = track.artist
		if track.album ~= nil and track.album ~= "" and track.album ~= track.title then
			subtitle = subtitle .. " · " .. track.album
		end
		trackSubtitles[track] = subtitle
	end
	return subtitle
end

-- The panel's title names the playlist it fills, and a rename changes the name in place: the name
-- the label was made from is kept beside it, and only a different name rebuilds the line.
---@class beat.PlaylistAdderHeading
---@field name string
---@field label string

---@type table<beat.Playlist, beat.PlaylistAdderHeading>
local headings = setmetatable({}, { __mode = "k" })

---@param playlist beat.Playlist
---@return string
local function playlistHeading(playlist)
	local kept = headings[playlist]
	if kept == nil or kept.name ~= playlist.name then
		kept = { name = playlist.name, label = "Add to " .. playlist.name }
		headings[playlist] = kept
	end
	return kept.label
end

---@class beat.PlaylistAdderOverlay: beat.OverlaySurface
local playlistAdder = {}

---@param params { playlistId: number }
---@param app beat.App
function playlistAdder.new(app, params)
	local playlist = app.services.collections.taxonomy:playlist(params.playlistId)
	if playlist == nil or app.services.library.current == nil then return nil end
	-- The search field is where typing goes the moment the panel opens.
	app:focusField("playlistAddSearch")
	app.services.scroll:reset(SCROLL_KEY)
	---@type beat.PlaylistAdderState
	local state = { playlistId = playlist.id, query = "", mode = "albums", scrollMax = 0 }
	state.scrollHandler = function(by, to)
		return { type = "scroll", key = SCROLL_KEY, max = state.scrollMax, by = by, to = to }
	end
	return state
end

---@param app beat.App
function playlistAdder.close(app)
	app:focusField(nil)
end

--- The row a track has in the playlist as the page lists it: a manual playlist walks the library
--- in order, so the key that left is the row that comes back.
---@param app beat.App
---@param playlist beat.Playlist
---@param track beat.Track
---@return number?
local function playlistIndexOf(app, playlist, track)
	local key = names.trackKey(track)
	local tracks = app.services.collections:playlistTracks(playlist)
	for at = 1, #tracks do
		local candidate = tracks[at]
		if candidate == track or names.trackKey(candidate) == key then return at end
	end
	return nil
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.PlaylistAdderState>
---@param message beat.Message
function playlistAdder.update(app, overlay, message)
	local state = overlay.state
	local kind = message.type
	if kind == "search" then
		-- The field is the app's own search pill, so what it types arrives as a search -- while a
		-- panel is open, that search belongs to the panel rather than to the top bar.
		state.query = message.value or ""
		app.services.scroll:reset(SCROLL_KEY)
		app:refresh()
		return true
	elseif kind == "playlistAdderMode" then
		if state.mode ~= message.value then
			state.mode = message.value == "tracks" ? "tracks" : "albums"
			app.services.scroll:reset(SCROLL_KEY)
			app:refresh()
		end
		return true
	end

	local playlist = app.services.collections.taxonomy:playlist(state.playlistId)
	local library = app.services.library.current
	if playlist == nil or library == nil then return false end

	if kind == "playlistAddAlbum" then
		local album = library:album(tonumber(message.id) or 0)
		if album ~= nil then
			app.services.collections.taxonomy:setPlaylistAlbum(playlist, album)
			app.services.collections:save()
			app.services.toasts:show("Added " .. album.title .. " to " .. playlist.name)
		end
		app:refresh()
		return true
	elseif kind == "playlistRemoveAlbum" then
		local album = library:album(tonumber(message.id) or 0)
		if album ~= nil then
			app.services.collections.taxonomy:setPlaylistAlbum(playlist, album, false)
			app.services.collections:save()
			app.services.toasts:show("Removed " .. album.title .. " from " .. playlist.name)
		end
		app:refresh()
		return true
	elseif kind == "playlistAddTrack" then
		local track = library:track(tonumber(message.id) or 0)
		if track ~= nil then
			app.services.collections.taxonomy:setPlaylistTrack(playlist, names.trackKey(track), true)
			app.services.collections:save()
			app.services.toasts:show("Added " .. track.title .. " to " .. playlist.name)
		end
		app:refresh()
		return true
	elseif kind == "playlistAdderRemoveTrack" then
		local track = library:track(tonumber(message.id) or 0)
		local index = track ~= nil and playlistIndexOf(app, playlist, track) or nil
		if index ~= nil then
			-- The removal is the collections service's, so its toast and its write are the ones
			-- that already exist for a row on the playlist page.
			app:act({ type = "playlistRemove", playlist = playlist.id, index = index })
		end
		return true
	end
	return false
end

--- The soft circle that ends a row: a plus that adds, or the check that says it is already in.
--- It is the row's own child, so its hover and its press are inside the row's box rather than
--- hanging off the row's edge.
---@param ctx beat.ui.Context
---@param theme beat.Theme
---@param styles beat.PlaylistAdderStyles
---@param added boolean
---@param action any?
---@return wonderland.Element
local function trailing(ctx, theme, styles, added, action)
	local box = div()
		:style(added ? styles.trailDone : styles.trailBase)
		:hover(added ? styles.trailDoneHover : styles.trailHover)
		:children(
			{
				ui.icon(
					ctx,
					{
						name = added ? "check" : "add",
						size = styles.trailIcon,
						colour = added ? theme.accentInk : theme:color("accent")
					}
				)
			}
		)
		:named(TRAIL_NAME)
	if action ~= nil then box:onClick(action) end
	return box
end

--- One row of either list: a cover, the item's two lines and the mark that ends it.
---@param app beat.App
---@param ctx beat.ui.Context
---@param styles beat.PlaylistAdderStyles
---@param hasCover boolean
---@param album beat.Album?
---@param title string
---@param subtitle string
---@param added boolean
---@param action any?
---@param key string
---@return wonderland.Element
local function adderRow(app, ctx, styles, hasCover, album, title, subtitle, added, action, key)
	local theme = app.services.appearance.theme
	local art
	if hasCover and album ~= nil then
		art = cover.view(app, { album = album, size = styles.coverSize, radius = theme:radius("sm") })
	else
		art = div()
			:style(styles.fallbackCover)
			:children({ ui.icon(ctx, { name = "musicalNote", size = styles.trailIcon, colour = theme:color("muted") }) })
	end

	local row = ui.listRow(
		ctx,
		{
			height = styles.rowHeight,
			padding = styles.rowPadding,
			gap = styles.rowGap,
			onClick = action,
			key = key,
			children = {
				art,
				div()
					:style(styles.names)
					:children({ text(title):style(styles.title), text(subtitle):style(styles.subtitle) }),
				trailing(ctx, theme, styles, added, action)
			}
		}
	)
	return row:named(ROW_NAME)
end

--- Whether every track on the album is in the playlist already. An album holds the mark when it
--- has nothing left to add; a partly added one still offers the plus, and adding it again fills
--- the rest without touching the keys that are there. The keys are the playlist's own set, built
--- once per taxonomy revision rather than walked from the album on every frame.
---@param memberKeys table<string, boolean>
---@param album beat.Album
---@return boolean
local function albumAdded(memberKeys, album)
	local tracks = album.tracks
	local count = #tracks
	if count == 0 then return false end
	for at = 1, count do
		if memberKeys[names.trackKey(tracks[at])] ~= true then return false end
	end
	return true
end

---@param state beat.PlaylistAdderState
---@param height number
---@return wonderland.StyleBuilder
local function spacerStyle(state, height)
	local spacers = state.spacers
	if spacers == nil then
		spacers = {}
		state.spacers = spacers
	end
	local style = spacers[height]
	if style == nil then
		style = sty():h(height)
		spacers[height] = style
	end
	return style
end

--- The panel's own boxes, kept for the size they were made at: the dialog is rebuilt on every
--- pointer move and every scroll step, and nothing but the window's size and the list's height
--- changes any of them.
---@class beat.PlaylistAdderFrame
---@field content number
---@field listWidth number
---@field listHeight number
---@field total number
---@field under number
---@field inset number
---@field sheet boolean
---@field windowWidth number
---@field windowHeight number
---@field header wonderland.StyleBuilder
---@field list wonderland.StyleBuilder
---@field panel wonderland.StyleBuilder
---@field sheetBox wonderland.StyleBuilder
---@field overlay wonderland.StyleBuilder

---@param theme beat.Theme
---@param width number
---@param content number
---@param listWidth number
---@param listHeight number
---@param total number
---@param under number
---@param inset number
---@param sheet boolean
---@param headerHeight number
---@param pad number
---@param gap number
---@param barWidth number
---@param window wonderland.RenderWindow
---@return beat.PlaylistAdderFrame
local function adderFrame(
	theme,
	width,
	content,
	listWidth,
	listHeight,
	total,
	under,
	inset,
	sheet,
	headerHeight,
	pad,
	gap,
	barWidth,
	window
)
	local byKey = styleCache.of(theme, "playlistAdderFrame", width)
	local frame = byKey[0] --[[@as beat.PlaylistAdderFrame?]]
	if
		frame ~= nil
		and frame.content == content
		and frame.listWidth == listWidth
		and frame.listHeight == listHeight
		and frame.total == total
		and frame.under == under
		and frame.inset == inset
		and frame.sheet == sheet
		and frame.windowWidth == window.width
		and frame.windowHeight == window.height
	then
		return frame
	end

	local radius = theme:radius("lg")
	frame = {
		content = content,
		listWidth = listWidth,
		listHeight = listHeight,
		total = total,
		under = under,
		inset = inset,
		sheet = sheet,
		windowWidth = window.width,
		windowHeight = window.height,
		header = sty():row():wrel(1.0):h(headerHeight):gap(theme:px(8)):align("center"),
		list = sty():column():w(content):h(listHeight):bar(barWidth, theme:px(32), theme:color("faint")),
		panel = sty()
			:w(width):h(total + under):column():pad(pad, pad, pad + under, pad):gap(gap):radius(radius)
			:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
			:shadow(0, theme:px(14), theme:px(36), "#00000080"),
		sheetBox = sty():w(width):h(total + inset),
		overlay = sty()
			:size(window.width, window.height):offset(0, 0):z(122):column():align("center")
			:justify(sheet ? "end" : "center"):bg(theme:color("overlay"))
	}
	byKey[0] = frame
	return frame
end

--- The section's count line is a formatted string; it is rebuilt when the number or the section it
--- counts changes, not on every frame the list is drawn.
---@param state beat.PlaylistAdderState
---@param count number
---@return string
local function sectionCount(state, count)
	if state.countAt ~= count or state.countMode ~= state.mode then
		state.countAt = count
		state.countMode = state.mode
		state.countLabel = format.count(count, state.mode == "albums" and "album" or "track")
	end
	return state.countLabel
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.PlaylistAdderState>
---@param window wonderland.RenderWindow
function playlistAdder.view(app, overlay, window)
	local state = overlay.state
	local playlist = app.services.collections.taxonomy:playlist(state.playlistId)
	local library = app.services.library.current
	if playlist == nil or library == nil then return nil end

	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local sheet = ctx.mobile
	local filtering = state.query:match("%S") ~= nil

	---@type beat.Album[]
	local albums = {}
	---@type beat.Track[]
	local tracks = {}
	if state.mode == "albums" then
		if filtering then
			albums = select(1, library:search(state.query))
		else
			albums = library.albums
		end
	else
		if filtering then
			tracks = select(3, library:search(state.query))
		else
			tracks = library.tracks
		end
	end

	local width = sheet and window.width or ctx:panelWidth(520)
	local pad = theme:px(sheet and 20 or 18)
	local gap = theme:px(sheet and 14 or 12)
	local content = width - pad * 2
	local headerHeight = theme:px(28)
	local searchHeight = theme:px(sheet and 46 or 38)
	local toggleHeight = theme:px(34)
	local sectionHeight = theme:px(20)
	local barWidth = theme:px(6)
	local _, inset = metrics.insets()

	local count = state.mode == "albums" and #albums or #tracks
	local contentStyles = adderStyles(theme, content)
	local removable = playlist.manual == true and playlist.smart ~= true

	local rowHeight = contentStyles.rowHeight
	local listHeight, listWidth
	local fullHeight, scrollMax, offset, first, last, top
	if count == 0 then
		listHeight = theme:px(176)
		listWidth = content
	else
		fullHeight = count * rowHeight
		local fixed = pad * 2 + headerHeight + searchHeight + toggleHeight + sectionHeight + gap * 4
		local available = window.height - fixed - (sheet and inset or theme:px(24))
		local listMax = math.max(rowHeight * 2, math.min(theme:px(sheet and 420 or 380), available))
		listHeight = math.min(fullHeight, listMax)
		scrollMax = math.max(0, fullHeight - listHeight)
		listWidth = scrollMax > 0 and (content - barWidth) or content
		offset = math.min(app.services.scroll:offset(SCROLL_KEY), scrollMax)
		app.services.scroll:setLimit(SCROLL_KEY, scrollMax)
		state.scrollMax = scrollMax
		first, last, top = app.services.scroll.slices(count, 1, rowHeight, offset, listHeight)
	end

	local total = pad * 2 + headerHeight + searchHeight + toggleHeight + sectionHeight + listHeight + gap * 4
	local radius = theme:radius("lg")
	local under = sheet and (inset + radius) or 0
	local frame = adderFrame(
		theme,
		width,
		content,
		listWidth,
		listHeight,
		total,
		under,
		inset,
		sheet,
		headerHeight,
		pad,
		gap,
		barWidth,
		window
	)

	local list
	if count == 0 then
		local title = state.mode == "albums" ? "No albums found" : "No tracks found"
		local copy = filtering and "Try another search." or "This library has nothing to show here."
		local styles = contentStyles
		list = div()
			:style(styles.emptyBlock)
			:children(
				{
					div()
						:style(styles.emptyIcon)
						:children(
							{
								ui.icon(
									ctx,
									{
										name = state.mode == "albums" and "disc" or "musicalNote",
										size = theme:px(22),
										colour = theme:color("accent")
									}
								)
							}
						),
					text(title):style(styles.emptyTitle),
					text(copy):style(styles.emptyCopy)
				}
			)
	else
		local styles = adderStyles(theme, listWidth)
		-- The keys the playlist holds, made once per taxonomy revision rather than walking an
		-- album's tracks through the tag map for every visible row on every frame.
		local memberKeys = app.services.collections:playlistKeySet(playlist)
		local rows = {}
		if top > 0 then rows[#rows + 1] = div():style(spacerStyle(state, top)) end

		if state.mode == "albums" then
			for at = first, last do
				local album = albums[at]
				local added = albumAdded(memberKeys, album)
				local action = added ? (removable and albumRemove(album) or nil) : albumAdd(album)
				rows[#rows + 1] = adderRow(
					app,
					ctx,
					styles,
					true,
					album,
					album.title,
					album.artist,
					added,
					action,
					albumRowKey(album)
				)
			end
		else
			for at = first, last do
				local track = tracks[at]
				local added = memberKeys[names.trackKey(track)] == true
				local action = added ? (removable and trackRemove(track) or nil) : trackAdd(track)
				local album = library:album(track.albumId)
				rows[#rows + 1] = adderRow(
					app,
					ctx,
					styles,
					album ~= nil,
					album,
					track.title,
					trackSubtitle(track),
					added,
					action,
					trackRowKey(track)
				)
			end
		end

		local bottom = fullHeight - top - (last - first + 1) * rowHeight
		if bottom > 0 then rows[#rows + 1] = div():style(spacerStyle(state, bottom)) end

		list = div()
			:style(frame.list):scroll(offset)
			:onScroll(state.scrollHandler):children(rows)
	end

	local segment = settingsList.segmented(
		app,
		{
			options = state.mode == "albums" and ALBUM_OPTIONS or TRACK_OPTIONS,
			width = content,
			height = toggleHeight
		}
	)
	local section = div()
		:style(contentStyles.section)
		:children(
			{
				text(state.mode == "albums" ? "Albums" : "Tracks"):style(contentStyles.sectionTitle),
				text(sectionCount(state, count)):style(contentStyles.sectionCount)
			}
		)

	local header = div()
		:style(frame.header)
		:children(
			{
				text(playlistHeading(playlist)):style(contentStyles.headerTitle),
				ui.iconButton(ctx, { name = "close", size = theme:px(28), onClick = { type = "dismiss" } })
			}
		)

	local search = searchField.view(
		ctx,
		{
			name = "playlistAddSearch",
			value = state.query,
			width = content,
			height = searchHeight,
			placeholder = "Search albums and tracks"
		}
	)

	local panel = div()
		:style(frame.panel):onClick({ type = "keep" }):children({ header, search, segment, section, list })
	if sheet then panel = div():style(frame.sheetBox):children({ panel }) end

	return div()
		:style(frame.overlay):onClick({ type = "dismiss" }):children({ panel })
end

return playlistAdder
