-- Editing the tags of a track, or the ones an album's tracks share. The dialog keeps a draft of
-- each field; saving sends only the fields that differ from what the library showed, so a field
-- left alone is never rewritten from the library's idea of it (a title made from a file name, an
-- album artist filled in from the artist). An emptied field removes the tag. The writing itself is
-- the metadata service's.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local styleCache = require("beat.app.components.helpers.styles")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.MetadataField
---@field key string # The treble.TagChanges field it writes
---@field label string
---@field icon string # A glyph name from beat-ui's icon component
---@field number boolean? # Written as a whole number

-- Each field leads with the mark of what it holds: a note for the title, a person for the artist,
-- a disc for the album, a group for the album artist, a numbered list for the track and disc, a
-- calendar for the year and a tag for the genre.
---@type beat.MetadataField[]
local TRACK_FIELDS = {
	{ key = "title", label = "Title", icon = "musicalNote" },
	{ key = "artist", label = "Artist", icon = "person" },
	{ key = "album", label = "Album", icon = "disc" },
	{ key = "albumArtist", label = "Album artist", icon = "people" },
	{ key = "track", label = "Track", icon = "listNumber", number = true },
	{ key = "disc", label = "Disc", icon = "listNumber", number = true },
	{ key = "date", label = "Year", icon = "calendar" },
	{ key = "genre", label = "Genre", icon = "tag" }
}

---@type beat.MetadataField[]
local ALBUM_FIELDS = {
	{ key = "album", label = "Album", icon = "disc" },
	{ key = "albumArtist", label = "Album artist", icon = "people" },
	{ key = "date", label = "Year", icon = "calendar" },
	{ key = "genre", label = "Genre", icon = "tag" }
}

-- The glyph column every field row leads with, the same square and the same muted colour as a
-- menu's rows. It is one size for the theme and the dialog redraws while it is open, so the box
-- is made once per theme rather than once per row and frame.
local ICON_SIZE = 16
local ICON_GAP = 10

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

---@param ctx beat.ui.Context
---@param theme beat.Theme
---@param name string
---@return wonderland.Element
local function iconColumn(ctx, theme, name)
	return div():style(iconBox(theme)):children(ui.icon(ctx, {
		name = name,
		size = theme:px(ICON_SIZE),
		colour = theme:color("muted")
	}))
end

-- Each field's focus name, made once rather than per frame.
---@type table<string, string>
local FOCUS = {}
for _, field in ipairs(TRACK_FIELDS) do FOCUS[field.key] = "metadata:" .. field.key end

---@class beat.MetadataEditorState: beat.OverlayState
---@field kind "track"|"album"
---@field heading string
---@field trackIds number[]
---@field fields beat.MetadataField[]
---@field initial table<string, string>
---@field draft table<string, string>
---@field rewriteLabel string? # The line under an album's fields, made with the dialog

---@param value any
---@return string
local function shown(value)
	if value == nil then return "" end
	return tostring(value)
end

--- The value the tracks share, or "" when they differ. There is at least one track.
---@param tracks beat.Track[]
---@param key string
---@return string
local function shared(tracks, key)
	local first = shown(tracks[1][key])
	for at = 2, #tracks do
		if shown(tracks[at][key]) ~= first then return "" end
	end
	return first
end

---@class beat.MetadataEditorOverlay: beat.OverlaySurface
local editor = {}

---@param app beat.App
---@param params { kind: string?, id: number? }
---@return beat.MetadataEditorState?
function editor.new(app, params)
	local library = app.services.library.current
	if library == nil or params.id == nil then return nil end

	---@type beat.MetadataEditorState
	local state
	if params.kind == "track" then
		local track = library:track(params.id)
		if track == nil then return nil end
		state = {
			kind = "track",
			heading = "Edit track",
			trackIds = { track.id },
			fields = TRACK_FIELDS,
			initial = {
				title = track.title,
				artist = track.artist,
				album = track.album,
				albumArtist = track.albumArtist,
				track = shown(track.number),
				disc = shown(track.disc),
				date = shown(track.year),
				genre = shown(track.genre)
			},
			draft = {}
		}
	elseif params.kind == "album" then
		local album = library:album(params.id)
		if album == nil or #album.tracks == 0 then return nil end
		local ids = {}
		for at, track in ipairs(album.tracks) do ids[at] = track.id end
		state = {
			kind = "album",
			heading = "Edit album",
			trackIds = ids,
			fields = ALBUM_FIELDS,
			initial = {
				album = album.title,
				albumArtist = album.artist,
				date = shown(album.year),
				genre = shared(album.tracks, "genre")
			},
			draft = {},
			rewriteLabel = #ids .. (#ids == 1 and " track" or " tracks") .. " will be rewritten"
		}
	else
		return nil
	end

	for key, value in pairs(state.initial) do state.draft[key] = value end
	local first = state.fields[1].key
	app:focusField(FOCUS[first], #state.draft[first])
	return state
end

---@param app beat.App
---@param _overlay beat.OverlayInstance<beat.MetadataEditorState>
function editor.close(app, _overlay)
	app:focusField(nil)
end

--- The fields that changed, as tag changes; nil and the reason when one cannot be written.
---@param state beat.MetadataEditorState
---@return treble.TagChanges? changes
---@return string? err
local function changesOf(state)
	local changes = {}
	for _, field in ipairs(state.fields) do
		local key = field.key
		local value = state.draft[key]:match("^%s*(.-)%s*$")
		if value ~= state.initial[key] then
			if value == "" then
				changes[key] = false
			elseif field.number then
				local number = tonumber(value)
				if number == nil or number < 0 or number % 1 ~= 0 then return nil, field.label .. " must be a whole number" end
				changes[key] = number
			else
				changes[key] = value
			end
		end
	end
	return changes
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.MetadataEditorState>
local function save(app, overlay)
	local state = overlay.state
	local changes, err = changesOf(state)
	if changes == nil then
		app.services.toasts:show(err or "These tags can't be written", "error")
		return
	end
	app:close(overlay)
	if next(changes) ~= nil then app:act({ type = "writeMetadata", trackIds = state.trackIds, changes = changes }) end
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.MetadataEditorState>
---@param message beat.Message
function editor.update(app, overlay, message)
	if message.type == "metadataDraft" then
		overlay.state.draft[message.field] = message.value or ""
		app:refresh()
	elseif message.type == "metadataSave" then
		save(app, overlay)
	elseif message.type == "metadataCancel" then
		app:close(overlay)
	else
		return false
	end
	return true
end

local SAVE = { type = "metadataSave" }
local CANCEL = { type = "metadataCancel" }

-- One draft handler per field, and one submit for the form: the dialog is built again on every
-- keystroke, and a closure per field per frame is one the trace compiler closes each time.
---@type table<string, fun(value: string): table>
local inputHandlers = {}

---@param key string
---@return fun(value: string): table
local function inputFor(key)
	local handler = inputHandlers[key]
	if handler == nil then
		handler = |value| -> { type = "metadataDraft", field = key, value = value }
		inputHandlers[key] = handler
	end
	return handler
end

---@return table
local function submitSave()
	return SAVE
end

--- What the dialog keeps for one width and height: its labels, the row each field sits in, the
--- heading, the count line and the panel. Nothing but the window's size and the number of fields
--- changes them, and the dialog is rebuilt while it is open.
---@class beat.MetadataEditorStyles
---@field width number
---@field height number
---@field windowWidth number
---@field windowHeight number
---@field heading wonderland.StyleBuilder
---@field label wonderland.StyleBuilder
---@field row wonderland.StyleBuilder
---@field countLabel wonderland.StyleBuilder
---@field actions wonderland.StyleBuilder
---@field panel wonderland.StyleBuilder
---@field overlay wonderland.StyleBuilder

---@param theme beat.Theme
---@param width number
---@param height number
---@param window wonderland.RenderWindow
---@return beat.MetadataEditorStyles
local function editorStyles(theme, width, height, window)
	local byKey = styleCache.of(theme, "metadataEditor", width)
	local record = byKey[0] --[[@as beat.MetadataEditorStyles?]]
	if
		record ~= nil
		and record.height == height
		and record.windowWidth == window.width
		and record.windowHeight == window.height
	then
		return record
	end

	local padding = theme:px(16)
	local rowHeight = theme:px(34)
	local gap = theme:px(10)
	local labelWidth = theme:px(96)
	record = {
		width = width,
		height = height,
		windowWidth = window.width,
		windowHeight = window.height,
		heading = theme:s():text(theme:type("lg")):weight("bold"):fg(theme:color("text")),
		label = theme:s():w(labelWidth):text(theme:type("sm")):fg(theme:color("muted")):ellipsis(),
		row = sty():row():h(rowHeight):gap(gap):align("center"),
		countLabel = theme:s():text(theme:type("xs")):fg(theme:color("faint")),
		actions = sty():row():h(theme:px(32)):gap(theme:px(8)):align("center"):justify("end"),
		panel = sty()
			:w(width):h(height):column():pad(padding):gap(gap):radius(theme:radius("md")):bg(theme:color("elevated"))
			:border(theme:px(1), theme:color("border")):shadow(0, theme:px(14), theme:px(36), "#00000099"),
		overlay = sty()
			:size(window.width, window.height):offset(0, 0):z(132):column():align("center"):justify("center")
			:bg(theme:color("overlay"))
	}
	byKey[0] = record
	return record
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.MetadataEditorState>
---@param window wonderland.RenderWindow
---@return wonderland.Element
function editor.view(app, overlay, window)
	local state = overlay.state
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local width = math.min(theme:px(440), window.width - theme:px(32))
	local padding = theme:px(16)
	local rowHeight = theme:px(34)
	local gap = theme:px(10)
	local iconSize = theme:px(ICON_SIZE)
	local iconGap = theme:px(ICON_GAP)
	local labelWidth = theme:px(96)
	local fieldWidth = width - padding * 2 - iconSize - iconGap - labelWidth - gap

	local count = #state.fields
	local height = padding * 2 + theme:px(28) + count * (rowHeight + gap) + theme:px(32) + gap
		+ (state.kind == "album" and theme:px(18) + gap or 0)
	local styles = editorStyles(theme, width, height, window)

	local rows = {
		text(state.heading):style(styles.heading)
	}
	for at = 1, count do
		local field = state.fields[at]
		local key = field.key
		rows[#rows + 1] = div():style(styles.row):children({
			iconColumn(ctx, theme, field.icon),
			text(field.label):style(styles.label),
			ui.field(ctx, {
				name = FOCUS[key],
				value = state.draft[key],
				placeholder = state.kind == "album" and key == "genre" and state.initial.genre == "" and "Mixed" or "",
				width = fieldWidth,
				oninput = inputFor(key),
				onsubmit = submitSave
			})
		})
	end
	if state.kind == "album" then
		rows[#rows + 1] = text(assert(state.rewriteLabel)):style(styles.countLabel)
	end
	rows[#rows + 1] = div()
		:style(styles.actions)
		:children({
			ui.button(ctx, { label = "Cancel", onClick = CANCEL, height = theme:px(30), width = theme:px(80) }),
			ui.button(ctx, { label = "Save", onClick = SAVE, variant = "primary", height = theme:px(30), width = theme:px(74) })
		})

	local panel = div():style(styles.panel):onClick({ type = "keep" }):children(rows)

	return div():style(styles.overlay):children({ panel })
end

return editor
