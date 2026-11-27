-- One context menu for every list in the app. The open message names the menu and the thing it is
-- for; the entries are whatever the registry has for that menu, in order. A plugin adds an entry
-- by registering an action rather than by writing a second menu, so the look and the closing rules
-- stay in one place. A menu whose subject has a rating leads with its stars: they set a value
-- rather than open something, so they are a row of their own instead of an action.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local styleCache = require("beat.app.components.helpers.styles")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.MenuState
---@field menu string
---@field id number? # The thing the menu is for; the player's menus have no subject
---@field source string? # For a page's shuffle menu, the kind of thing `id` names
---@field messages table[]? # The fixed entries' messages, built when the menu opens
---@field entries table[]? # The registry actions the menu shows, built when it opens
---@field rating { value: number, onRate: fun(stars: number): table }? # Its stars, when the subject has them
---@field playlistId number? # The manual playlist page a track menu was opened from
---@field index number? # And the row in that playlist the track sits at
---@field x number
---@field y number
---@field at { theme: beat.Theme, width: number, height: number, x: number, y: number, style: wonderland.StyleBuilder }? # The box that places the panel, kept for this opening

-- Each menu keeps the width it had when it was its own overlay: enough for its longest entry.
local WIDTH = { album = 218, track = 210, playlist = 196, shuffle = 210, skip = 210 }

-- The glyph column of a menu row. Every row leads with the same square, whether or not a plugin
-- gave its action an icon, so the titles line up down the menu.
local ICON_SIZE = 16
local ICON_GAP = 10

-- The square is one size for the whole theme, and a menu draws its rows on every frame it is
-- open, so it is made once per theme rather than once per row.
---@type table<beat.Theme, wonderland.StyleBuilder>
local iconBoxes = setmetatable({}, { __mode = "k" })

---@param theme beat.Theme
---@return wonderland.StyleBuilder
local function iconBox(theme)
	local box = iconBoxes[theme]
	if box == nil then
		local size = theme:px(ICON_SIZE)
		box = sty():size(size, size):row():align("center"):justify("center")
		iconBoxes[theme] = box
	end
	return box
end

--- The fixed icon column an entry starts with. A missing glyph leaves the square empty so the
--- title still starts at the same place as every other row's.
---@param ctx beat.ui.Context
---@param theme beat.Theme
---@param name string?
---@return wonderland.Element
local function iconColumn(ctx, theme, name)
	if name == nil then return div():style(iconBox(theme)) end
	return div():style(iconBox(theme)):children(ui.icon(ctx, {
		name = name,
		size = theme:px(ICON_SIZE),
		colour = theme:color("muted")
	}))
end

--- What the entries are shown for. The menu is refused when the library or the taxonomy no longer
--- has the thing it was opened on, which is what the three menus used to decide one at a time.
---@type table<string, fun(app: beat.App, id: number): table?>
local CONTEXT = {
	---@param app beat.App
	---@param id number
	album = function(app, id)
		local library = app.services.library.current
		local album = library ~= nil ? (library:album(id)) : nil
		return album ~= nil ? { album = album } : nil
	end,
	---@param app beat.App
	---@param id number
	track = function(app, id)
		local library = app.services.library.current
		local track = library ~= nil ? (library:track(id)) : nil
		return track ~= nil ? { track = track } : nil
	end,
	---@param app beat.App
	---@param id number
	playlist = function(app, id)
		local playlist = app.services.collections.taxonomy:playlist(id)
		return playlist ~= nil ? { playlist = playlist } : nil
	end
}

-- The manual playlist whose page the track menu was opened on. A track row drawn on a playlist
-- page is one of that playlist's rows, so the page names the list the menu can take the track out
-- of. A smart or built-in list has no hand-added row to remove: its contents are its rules or the
-- library itself, so neither offers the entry.
---@param app beat.App
---@param trackId number
---@return number? playlistId
---@return number? index
local function playlistRowFor(app, trackId)
	local page = app.page
	if page == nil or page.kind ~= "playlist" then return nil, nil end
	local collections = app.services.collections
	local playlist = collections.taxonomy:playlist(page.id)
	if playlist == nil or playlist.builtin or playlist.smart or not playlist.manual then return nil, nil end
	local tracks = collections:playlistTracks(playlist)
	for at = 1, #tracks do
		if tracks[at].id == trackId then return playlist.id, at end
	end
	return nil, nil
end

-- The stars a rated menu leads with send a message naming the album, one handler per album rather
-- than one per frame the menu is open.
---@type table<beat.Album, fun(stars: number): table>
local rateHandlers = setmetatable({}, { __mode = "k" })

---@param album beat.Album
---@return fun(stars: number): table
local function rateFor(album)
	local handler = rateHandlers[album]
	if handler == nil then
		local id = album.id
		handler = |stars| -> { type = "rateAlbum", id = id, stars = stars }
		rateHandlers[album] = handler
	end
	return handler
end

--- The menus whose subject can be rated, with its rating and the message a star sends. A star
--- sends its message like any entry, and the menu closes behind it the same way.
---@type table<string, fun(app: beat.App, ctx: table): { value: number, onRate: fun(stars: number): table }>
local RATING = {
	---@param app beat.App
	---@param ctx { album: beat.Album }
	album = function(app, ctx)
		local album = ctx.album
		return {
			value = app.services.collections.taxonomy:albumRating(album.key),
			onRate = rateFor(album)
		}
	end
}

-- The shuffle button's menu: the three modes, with a check beside the one in use. They are fixed
-- entries rather than registry actions because the menu is the player's own control rather than
-- something a plugin adds to. A page's shuffle button opens the same menu with a `source` and an
-- `id`, and then choosing a mode starts that playlist or album in it.
local SHUFFLE_ENTRIES = {
	{ mode = "tracks", title = "Shuffle tracks", icon = "shuffle" },
	{ mode = "albums", title = "Shuffle albums", icon = "disc" },
	{ mode = "artists", title = "Shuffle artists", icon = "person" }
}

--- The player's own shuffle menu changes the queue that is playing. A page's menu starts a new
--- queue instead, so the same rows send its playlist or album in the chosen mode.
---@type table<number, table>
local SHUFFLE_MESSAGES = {}
for at, entry in ipairs(SHUFFLE_ENTRIES) do
	SHUFFLE_MESSAGES[at] = { type = "shuffleMode", mode = entry.mode }
end

-- The skip button's menu: the rest of the album or artist that is playing is left behind. The
-- queue decides where the next group starts in whatever order it is in.
local SKIP_ENTRIES = {
	{ by = "album", title = "Skip album", icon = "disc" },
	{ by = "artist", title = "Skip artist", icon = "person" }
}

---@type table<number, table>
local SKIP_MESSAGES = {}
for at, entry in ipairs(SKIP_ENTRIES) do
	SKIP_MESSAGES[at] = { type = "skipGroup", by = entry.by }
end

--- The messages a page's shuffle menu rows send, one array built when the menu opens rather than
--- on every frame it is drawn. Without a page source the player's own fixed messages are used.
---@param source string?
---@param id number?
---@return table[]
local function messagesFor(source, id)
	local kind = source == "playlist" and "playPlaylist" or source == "album" and "playAlbum" or nil
	if kind == nil or id == nil then return SHUFFLE_MESSAGES end

	local messages = {}
	for at, entry in ipairs(SHUFFLE_ENTRIES) do
		messages[at] = { type = kind, id = id, shuffle = true, shuffleMode = entry.mode }
	end
	return messages
end

--- What the panel keeps for one width and height: the rows, the labels by tone, the check column
--- and the panel itself. A menu is light and rebuilt on every frame until a press closes it, so
--- these are made when that size is first drawn and reused after.
---@class beat.MenuStyles
---@field width number
---@field height number
---@field rowHeight number
---@field rowPad number
---@field checkSize number
---@field labelWidth number
---@field fixedLabel wonderland.StyleBuilder
---@field labels table<string, wonderland.StyleBuilder>
---@field check wonderland.StyleBuilder
---@field ratingRow wonderland.StyleBuilder
---@field ratingLabel wonderland.StyleBuilder
---@field panel wonderland.StyleBuilder
---@field frame wonderland.StyleBuilder

---@param theme beat.Theme
---@param width number
---@param height number
---@return beat.MenuStyles
local function menuStyles(theme, width, height)
	local byHeight = styleCache.of(theme, "menu", width)
	local record = byHeight[height] --[[@as beat.MenuStyles?]]
	if record ~= nil then return record end

	local rowHeight = theme:px(34)
	local pad = theme:px(8)
	local gap = theme:px(2)
	local rowPad = theme:px(12)
	local checkSize = theme:px(16)
	-- Fixed rows put the check past a label of this width, inside the row's padding.
	local labelWidth = width - pad * 2 - rowPad * 2 - theme:px(ICON_SIZE) - theme:px(ICON_GAP) * 2 - checkSize
	record = {
		width = width,
		height = height,
		rowHeight = rowHeight,
		rowPad = rowPad,
		checkSize = checkSize,
		labelWidth = labelWidth,
		fixedLabel = theme:s():w(labelWidth):text(theme:type("sm")):fg(theme:color("text")):ellipsis(),
		labels = {},
		check = sty():size(checkSize, checkSize),
		ratingRow = sty()
			:row():w(width - theme:px(16)):h(rowHeight):pad(0, rowPad, 0, rowPad)
			:gap(theme:px(ICON_GAP)):align("center"),
		ratingLabel = theme:s():w("auto"):text(theme:type("sm")):fg(theme:color("muted")),
		panel = sty()
			:w(width):h(height):column():pad(pad):gap(gap):radius(theme:radius("md"))
			:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
			:shadow(0, theme:px(12), theme:px(30), "#00000080"),
		frame = sty():fill():offset(0, 0):z(120)
	}
	byHeight[height] = record
	return record
end

--- The box that places the panel at the press, kept on the menu's state while its place and size
--- stay the same: a style holds the offset, so a new place is a new style, but it is made once per
--- opening rather than on every frame the panel is drawn.
---@param state beat.MenuState
---@param theme beat.Theme
---@param width number
---@param height number
---@param x number
---@param y number
---@return wonderland.StyleBuilder
local function positionedStyle(state, theme, width, height, x, y)
	local kept = state.at
	if
		kept ~= nil
		and kept.theme == theme
		and kept.width == width
		and kept.height == height
		and kept.x == x
		and kept.y == y
	then
		return kept.style
	end
	local style = sty():w(width):h(height):offset(x, y)
	state.at = { theme = theme, width = width, height = height, x = x, y = y, style = style }
	return style
end

--- The label of a plugin's entry, in the tone the action asked for: built the first time that
--- tone is drawn for this size, and read from the record after.
---@param record beat.MenuStyles
---@param theme beat.Theme
---@param tone string?
---@return wonderland.StyleBuilder
local function toneLabel(record, theme, tone)
	local key = tone or "text"
	local label = record.labels[key]
	if label == nil then
		label = theme:s():text(theme:type("sm")):fg(theme:color(key)):ellipsis()
		if key == "danger" then label = label:weight("semibold") end
		record.labels[key] = label
	end
	return label
end

--- A menu of fixed entries: the shuffle button's modes and the skip button's groups. Both belong
--- to the player rather than to a plugin, so they share this row drawing and differ only in their
--- entries, their messages and which row, if any, is marked as the one in use.
---@param app beat.App
---@param state beat.MenuState
---@param window wonderland.RenderWindow
---@param entries { title: string, icon: string }[]
---@param messages table[]
---@param widthUnits number
---@param active number? # 1-based entry marked with a check
---@return wonderland.Element
local function fixedView(app, state, window, entries, messages, widthUnits, active)
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local width = theme:px(widthUnits)
	local rowHeight = theme:px(34)
	local padding = theme:px(8)
	local gap = theme:px(2)
	local count = #entries
	local height = padding * 2 + count * rowHeight + (count - 1) * gap
	local margin = theme:px(8)
	local x = math.max(margin, math.min(state.x, window.width - width - margin))
	local y = math.max(margin, math.min(state.y, window.height - height - margin))
	local styles = menuStyles(theme, width, height)

	local rows = {}
	for at = 1, count do
		local entry = entries[at]
		local chosen = at == active
		local trailing
		if chosen then
			trailing = ui.icon(ctx, { name = "check", size = styles.checkSize, colour = theme:color("accent") })
		else
			trailing = div():style(styles.check)
		end
		rows[at] = ui.listRow(
			ctx,
			{
				height = rowHeight,
				padding = styles.rowPad,
				gap = theme:px(ICON_GAP),
				onClick = messages[at],
				children = {
					iconColumn(ctx, theme, entry.icon),
					text(entry.title):style(styles.fixedLabel),
					trailing
				}
			}
		)
	end

	local panel = div():style(styles.panel):onClick({ type = "keep" }):children(rows)

	-- The cover is the pointer's as well as the press's: what the menu is over is not hovered
	-- through it, and the panel painted inside it is, since it comes after it.
	return div()
		:style(styles.frame):blockPointer():onClick({ type = "dismiss" })
		:children({ div():style(positionedStyle(state, theme, width, height, x, y)):children({ panel }) })
end

---@class beat.MenuOverlay: beat.OverlaySurface
local menu = { light = true }

---@param params { menu: string, id: number?, source: string?, x: number?, y: number? }
---@param app beat.App
function menu.new(app, params)
	-- The player's own menus have no subject to look up: the shuffle button lists the modes
	-- whatever is playing, and the skip button the groups it can leave.
	if params.menu == "shuffle" or params.menu == "skip" then
		local x, y = params.x, params.y
		if x == nil or y == nil then
			local pointer = app.layoutPlugin ~= nil and app.window ~= nil and app.layoutPlugin:pointer(app.window) or nil
			x, y = pointer?.x or 0, pointer?.y or 0
		end
		local messages = params.menu == "skip" and SKIP_MESSAGES or messagesFor(params.source, params.id)
		---@type beat.MenuState
		return { menu = params.menu, id = params.id or 0, source = params.source, x = x, y = y, messages = messages }
	end

	local context = params.menu ~= nil and CONTEXT[params.menu] or nil
	if context == nil or params.id == nil then return nil end
	local item = context(app, params.id)
	if item == nil then return nil end
	-- A right-click says where it was. A tap on a menu button does not, and is answered while the
	-- finger is still down, so the pointer is where the button is and the menu opens beside it.
	local x, y = params.x, params.y
	if x == nil or y == nil then
		local pointer = app.layoutPlugin ~= nil and app.window ~= nil and app.layoutPlugin:pointer(app.window) or nil
		x, y = pointer?.x or 0, pointer?.y or 0
	end
	local playlistId, index
	if params.menu == "track" then playlistId, index = playlistRowFor(app, params.id) end

	-- The entries are the registry's, and its visibility tests and message builders are the
	-- plugin's: they are asked once when the menu opens, as the shuffle menu's messages are, rather
	-- than on every frame the light panel is drawn.
	local entries = app.registry:actions(params.menu, item)
	-- A track menu opened on a manual playlist page can take its subject out of that list. The
	-- entry is the menu's own rather than a plugin's: the playlist page is where the row and its
	-- place come from, and this is the one menu that has a row to remove.
	if params.menu == "track" and playlistId ~= nil and index ~= nil then
		local playlist = app.services.collections.taxonomy:playlist(playlistId)
		if playlist ~= nil and not playlist.builtin and not playlist.smart and playlist.manual then
			local track = app.services.collections:playlistTracks(playlist)[index]
			if track ~= nil and track.id == params.id then
				entries[#entries + 1] = {
					title = "Remove from playlist",
					icon = "close",
					tone = "danger",
					message = { type = "playlistRemove", playlist = playlist.id, index = index }
				}
			end
		end
	end

	local rateWith = RATING[params.menu]
	-- The stars are the ratings plugin's. Without it, the menu is only the actions other plugins
	-- registered, and the data Collections keeps is left alone for when the plugin comes back.
	local rating = rateWith ~= nil and app.registry:hasPlugin("ratings") and rateWith(app, item) or nil
	---@type beat.MenuState
	return {
		menu = params.menu,
		id = params.id,
		x = x,
		y = y,
		playlistId = playlistId,
		index = index,
		entries = entries,
		rating = rating
	}
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.MenuState>
---@param window wonderland.RenderWindow
function menu.view(app, overlay, window)
	local state = overlay.state
	if state.menu == "shuffle" then
		local queue = app.services.playback.player.queue
		local mode = queue?.shuffleMode or "off"
		local active
		for at, entry in ipairs(SHUFFLE_ENTRIES) do
			if entry.mode == mode then active = at end
		end
		return fixedView(app, state, window, SHUFFLE_ENTRIES, state.messages or SHUFFLE_MESSAGES, WIDTH.shuffle, active)
	end
	if state.menu == "skip" then
		return fixedView(app, state, window, SKIP_ENTRIES, SKIP_MESSAGES, WIDTH.skip)
	end

	local entries = state.entries
	local rating = state.rating
	if entries == nil then return nil end

	local theme = app.services.appearance.theme
	local uiCtx = app:ui(window)
	local width = theme:px(WIDTH[state.menu] or 218)
	local rowHeight = theme:px(34)
	local count = #entries + (rating ~= nil and 1 or 0)
	local height = theme:px(8 * 2 + 34 * count + 2 * math.max(0, count - 1))
	local margin = theme:px(8)
	local x = math.max(margin, math.min(state.x, window.width - width - margin))
	local y = math.max(margin, math.min(state.y, window.height - height - margin))
	local styles = menuStyles(theme, width, height)

	local rows = {}
	if rating ~= nil then
		rows[1] = div()
			:style(styles.ratingRow)
			:children(
				{
					iconColumn(uiCtx, theme, "star"),
					text("Rating"):style(styles.ratingLabel),
					ui.rating(uiCtx, { value = rating.value, onRate = rating.onRate, size = theme:px(16) })
				}
			)
	end
	for at = 1, #entries do
		local entry = entries[at]
		rows[#rows + 1] = ui.listRow(
			uiCtx,
			{
				height = rowHeight,
				padding = styles.rowPad,
				gap = theme:px(ICON_GAP),
				onClick = entry.message,
				children = { iconColumn(uiCtx, theme, entry.icon), text(entry.title):style(toneLabel(styles, theme, entry.tone)) }
			}
		)
	end

	local panel = div():style(styles.panel):onClick({ type = "keep" }):children(rows)

	-- The cover is the pointer's as well as the press's: what the menu is over is not hovered
	-- through it, and the panel painted inside it is, since it comes after it.
	return div()
		:style(styles.frame):blockPointer():onClick({ type = "dismiss" })
		:children({ div():style(positionedStyle(state, theme, width, height, x, y)):children({ panel }) })
end

return menu
