-- Where a track or a whole album goes: one row per playlist, with how many tracks it would hold.
-- With no playlist to offer, the panel says so and grows the first one around the item instead:
-- the listener came here to file something away, so the empty panel is the place to do it.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local format = require("beat.app.components.helpers.format")
local metrics = require("beat.app.components.helpers.metrics")
local names = require("beat.music.names")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.PlaylistPickerState
---@field kind "album"|"track"
---@field id number

---@class beat.PlaylistPickerStyles
---@field header wonderland.StyleBuilder
---@field title wonderland.StyleBuilder
---@field rowHeight number
---@field rowPadding number
---@field rowGap number
---@field name wonderland.StyleBuilder
---@field createName wonderland.StyleBuilder
---@field count wonderland.StyleBuilder
---@field badge wonderland.StyleBuilder
---@field divider wonderland.StyleBuilder
---@field emptyIcon wonderland.StyleBuilder
---@field emptyTitle wonderland.StyleBuilder
---@field emptyCopy wonderland.StyleBuilder

-- Every panel a picker draws shares these: the row's one height, padding and gap, the badge the
-- create row leads with, and the empty state's mark, title and copy. They are built once per theme
-- and panel width, not once per frame: the labels are boxes of their own so a long name ellipsizes
-- before it reaches the track count, which is why the width is part of the key.
---@type table<beat.Theme, table<number, beat.PlaylistPickerStyles>>
local stylesByTheme = setmetatable({}, { __mode = "k" })

---@param theme beat.Theme
---@param content number # The panel's inner width, which every box below is cut to
---@return beat.PlaylistPickerStyles
local function pickerStyles(theme, content)
	local byContent = stylesByTheme[theme]
	if byContent == nil then
		byContent = {}
		stylesByTheme[theme] = byContent
	end
	local styles = byContent[content]
	if styles == nil then
		local rowHeight = theme:px(38)
		local rowPadding = theme:px(10)
		local rowGap = theme:px(8)
		local inner = content - rowPadding * 2 - rowGap
		-- The count keeps a readable column even in a window narrow enough that a fixed one would
		-- leave the name nothing, which is how the two lines ended up drawn over one another.
		local countWidth = math.min(theme:px(80), math.max(theme:px(44), math.floor(inner * 0.35)))
		local nameWidth = math.max(theme:px(1), inner - countWidth)
		local badgeSize = theme:px(24)
		styles = {
			header = sty():row():wrel(1.0):h(theme:px(28)):gap(rowGap):align("center"):justify("space-between"),
			title = theme:s()
				:w(content - theme:px(28) - rowGap):text(theme:type("lg")):weight("bold"):fg(theme:color("text")):ellipsis(),
			rowHeight = rowHeight,
			rowPadding = rowPadding,
			rowGap = rowGap,
			name = theme:s():w(nameWidth):text(theme:type("sm")):fg(theme:color("text")):ellipsis(),
			createName = theme:s()
				:w(math.max(theme:px(1), inner - badgeSize)):text(theme:type("sm")):weight("semibold"):fg(theme:color("text"))
				:ellipsis(),
			count = theme:s():w(countWidth):text(theme:type("xs")):fg(theme:color("muted")):align("end"),
			badge = sty()
				:size(badgeSize, badgeSize):radius(theme:radius("full")):bg(theme:color("accent", 0.14)):row():align("center")
				:justify("center"),
			divider = sty():wrel(1.0):h(theme:px(1)):bg(theme:color("border")),
			emptyIcon = sty()
				:size(theme:px(56), theme:px(56)):radius(theme:radius("full")):bg(theme:color("accent", 0.14)):row():align("center")
				:justify("center"),
			emptyTitle = theme:s():text(theme:type("lg")):weight("semibold"):fg(theme:color("text")),
			emptyCopy = theme:s():text(theme:type("sm")):fg(theme:color("muted"))
		}
		byContent[content] = styles
	end
	return styles
end

---@class beat.PlaylistPickerOverlay: beat.OverlaySurface
local playlistPicker = {}

---@param params { kind: "album"|"track", id: number }
---@param app beat.App
function playlistPicker.new(app, params)
	if params.kind ~= "album" and params.kind ~= "track" then return nil end
	if params.id == nil then return nil end
	---@type beat.PlaylistPickerState
	return { kind = params.kind, id = params.id }
end

--- What the item is called, which is also what a playlist made for it starts out called.
---@param app beat.App
---@param state beat.PlaylistPickerState
---@return string? title
---@return beat.Album? album
---@return beat.Track? track
local function pickerItem(app, state)
	local library = app.services.library.current
	if library == nil then return nil, nil, nil end
	if state.kind == "album" then
		local album = library:album(state.id)
		return album ~= nil and album.title or nil, album, nil
	end
	local track = library:track(state.id)
	return track ~= nil and track.title or nil, nil, track
end

--- The name a new playlist starts with: the item's own, numbered if a list already has it, since a
-- playlist cannot be renamed and a bare "New playlist" would be a name it kept forever.
---@param taxonomy beat.Taxonomy
---@param title string
---@return string
local function freshPlaylistName(taxonomy, title)
	local taken = {}
	for _, playlist in ipairs(taxonomy.playlists) do
		taken[names.fold(playlist.name)] = true
	end
	if not taken[names.fold(title)] then return title end
	local suffix = 2
	while taken[names.fold(title .. " " .. suffix)] do suffix += 1 end
	return title .. " " .. suffix
end

--- A playlist holding the item the picker was opened for, saved and ready to name-check.
---@param app beat.App
---@param state beat.PlaylistPickerState
---@return beat.Playlist?
local function createPlaylistWithItem(app, state)
	local title, album, track = pickerItem(app, state)
	local name = title or "New playlist"
	if name:match("%S") == nil then name = "New playlist" end
	local taxonomy = app.services.collections.taxonomy
	local playlist = taxonomy:addPlaylist(freshPlaylistName(taxonomy, name), false, nil, nil, { manual = true })
	if playlist == nil then return nil end
	if album ~= nil then
		taxonomy:setPlaylistAlbum(playlist, album)
	elseif track ~= nil then
		taxonomy:setPlaylistTrack(playlist, names.trackKey(track), true)
	end
	return playlist
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.PlaylistPickerState>
---@param message beat.Message
function playlistPicker.update(app, overlay, message)
	local state = overlay.state
	if message.type == "addToPlaylist" then
		local playlist = app.services.collections.taxonomy:playlist(message.playlistId)
		local library = app.services.library.current
		if playlist ~= nil and library ~= nil then
			if state.kind == "album" then
				local album = library:album(state.id)
				if album ~= nil then app.services.collections.taxonomy:setPlaylistAlbum(playlist, album) end
			else
				local track = library:track(state.id)
				if track ~= nil then app.services.collections.taxonomy:setPlaylistTrack(playlist, names.trackKey(track), true) end
			end
			app.services.collections:save()
			app.services.toasts:show("Added to " .. playlist.name)
		end
		app:close(overlay)
		app:refresh()
		return true
	elseif message.type == "newPlaylistWithItem" then
		local playlist = createPlaylistWithItem(app, state)
		if playlist == nil then
			app.services.toasts:show("Could not create a playlist", "error")
		else
			app.services.collections:save()
			app.services.toasts:show("Added to " .. playlist.name)
			app:close(overlay)
		end
		app:refresh()
		return true
	end
	return false
end

--- One playlist, or the create row when `playlist` is nil: a mark, a name, and a track count.
--- The row is the shared list row, so its hover and press fill are the panel's inner width and its
--- content sits inside that fill, centred on one line; every row in the panel is the same width.
---@param app beat.App
---@param ctx beat.ui.Context
---@param playlist beat.Playlist?
---@param count number
---@param styles beat.PlaylistPickerStyles
---@return wonderland.Element
local function pickerRow(app, ctx, playlist, count, styles)
	local theme = app.services.appearance.theme
	local action = playlist ~= nil and { type = "addToPlaylist", playlistId = playlist.id } or {
		type = "newPlaylistWithItem"
	}
	local children
	if playlist == nil then
		children = {
			div()
				:style(styles.badge)
				:children({ ui.icon(ctx, { name = "add", size = theme:px(14), colour = theme:color("text") }) }),
			text("New playlist"):style(styles.createName)
		}
	else
		children = {
			text(playlist.name):style(styles.name),
			text(format.count(count, "track")):style(styles.count)
		}
	end
	return ui.listRow(
		ctx,
		{
			height = styles.rowHeight,
			padding = styles.rowPadding,
			gap = styles.rowGap,
			justify = playlist == nil and "start" or "space-between",
			onClick = action,
			children = children
		}
	)
end

--- How tall one line of text stands, close enough that the panel is cut to it before layout runs.
---@param size number
---@return number
local function lineHeight(size)
	return math.floor(size * 1.35)
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.PlaylistPickerState>
---@param window wonderland.RenderWindow
function playlistPicker.view(app, overlay, window)
	local state = overlay.state
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local taxonomy = app.services.collections.taxonomy
	local sheet = ctx.mobile

	local width = sheet and window.width or ctx:panelWidth(360)
	local pad = theme:px(sheet and 20 or 16)
	local gap = theme:px(sheet and 16 or 14)
	local content = width - pad * 2
	local headerHeight = theme:px(28)
	local styles = pickerStyles(theme, content)

	local count = #taxonomy.playlists
	local rows = {}
	if count > 0 then
		-- The create row leads the list: making a playlist is the other thing a listener comes here
		-- to do, and it costs one row to keep both answers in the same place.
		rows[#rows + 1] = pickerRow(app, ctx, nil, 0, styles)
		rows[#rows + 1] = div()
			:style(sty():wrel(1.0):h(theme:px(13)):pad(theme:px(6), 0, theme:px(6), 0)):children({ div():style(styles.divider) })
		for _, playlist in ipairs(taxonomy.playlists) do
			rows[#rows + 1] = pickerRow(app, ctx, playlist, #app.services.collections:playlistTracks(playlist), styles)
		end
	end

	---@type wonderland.Element[]
	local children = {
		div()
			:style(styles.header)
			:children(
				{
					text(state.kind == "album" ? "Add album to playlist" : "Add track to playlist"):style(styles.title),
					ui.iconButton(ctx, { name = "close", size = theme:px(28), onClick = { type = "dismiss" } })
				}
			)
	}

	local height = pad * 2 + headerHeight
	if count == 0 then
		local copy = state.kind == "album" and "Create one and this album goes straight in." or "Create one and this track goes straight in."
		local titleSize = theme:type("lg")
		local copySize = theme:type("sm")
		local innerGap = theme:px(14)
		local blockHeight = theme:px(56) + lineHeight(titleSize) + lineHeight(copySize) + theme:px(36) + innerGap * 3
		height += gap + blockHeight
		children[#children + 1] = div()
			:style(sty():column():wrel(1.0):gap(innerGap):align("center"))
			:children(
				{
					div()
						:style(styles.emptyIcon)
						:children({ ui.icon(ctx, { name = "playlists", size = theme:px(26), colour = theme:color("text") }) }),
					text("No playlists yet"):style(styles.emptyTitle),
					text(copy):style(styles.emptyCopy),
					ui.button(
						ctx,
						{
							label = "New playlist",
							icon = "add",
							onClick = { type = "newPlaylistWithItem" },
							variant = "primary",
							height = theme:px(36),
							width = theme:px(160)
						}
					)
				}
			)
	else
		local rowHeight = theme:px(38)
		local itemGap = theme:px(2)
		local listHeight = rowHeight + theme:px(13) + count * rowHeight + (count + 1) * itemGap
		height += gap + listHeight
		children[#children + 1] = div():style(sty():column():wrel(1.0):h(listHeight):gap(itemGap)):children(rows)
	end

	-- On a phone the panel is a sheet that rises from the bottom edge, its lower corners pushed past
	-- the screen and its foot clearing the gesture bar, as the equalizer's sheet does.
	local _, inset = metrics.insets()
	local radius = theme:radius("lg")
	local under = sheet and (inset + radius) or 0
	local panel = div()
		:style(
			sty()
				:w(width):h(height + under):column():pad(pad, pad, pad + under, pad):gap(gap):radius(radius)
				:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
				:shadow(0, theme:px(12), theme:px(30), "#00000080")
		):onClick({ type = "keep" }):children(children)
	if sheet then panel = div():style(sty():w(width):h(height + inset)):children({ panel }) end

	return div()
		:style(
			sty()
				:size(window.width, window.height):offset(0, 0):z(121):column():align("center"):justify(sheet ? "end" : "center")
				:bg(theme:color("overlay"))
		):onClick({ type = "dismiss" }):children({ panel })
end

return playlistPicker
