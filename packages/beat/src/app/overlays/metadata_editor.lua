-- Editing the tags of a track, or the ones an album's tracks share. The dialog keeps a draft of
-- each field; saving sends only the fields that differ from what the library showed, so a field
-- left alone is never rewritten from the library's idea of it (a title made from a file name, an
-- album artist filled in from the artist). An emptied field removes the tag. The writing itself is
-- the metadata service's.
local wonderland = require("wonderland")
local ui = require("beat-ui")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.MetadataField
---@field key string # The treble.TagChanges field it writes
---@field label string
---@field number boolean? # Written as a whole number

---@type beat.MetadataField[]
local TRACK_FIELDS = {
	{ key = "title", label = "Title" },
	{ key = "artist", label = "Artist" },
	{ key = "album", label = "Album" },
	{ key = "albumArtist", label = "Album artist" },
	{ key = "track", label = "Track", number = true },
	{ key = "disc", label = "Disc", number = true },
	{ key = "date", label = "Year" },
	{ key = "genre", label = "Genre" }
}

---@type beat.MetadataField[]
local ALBUM_FIELDS = {
	{ key = "album", label = "Album" },
	{ key = "albumArtist", label = "Album artist" },
	{ key = "date", label = "Year" },
	{ key = "genre", label = "Genre" }
}

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
			draft = {}
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
	local labelWidth = theme:px(96)
	local fieldWidth = width - padding * 2 - labelWidth - gap

	local rows = {
		text(state.heading):style(theme:s():text(theme:type("lg")):weight("bold"):fg(theme:color("text")))
	}
	local labelStyle = theme:s():w(labelWidth):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()
	local rowStyle = sty():row():h(rowHeight):gap(gap):align("center")
	for _, field in ipairs(state.fields) do
		local key = field.key
		rows[#rows + 1] = div():style(rowStyle):children({
			text(field.label):style(labelStyle),
			ui.field(ctx, {
				name = FOCUS[key],
				value = state.draft[key],
				placeholder = state.kind == "album" and key == "genre" and state.initial.genre == "" and "Mixed" or "",
				width = fieldWidth,
				oninput = |value| -> { type = "metadataDraft", field = key, value = value },
				onsubmit = || -> SAVE
			})
		})
	end
	if state.kind == "album" then
		rows[#rows + 1] = text(#state.trackIds .. (#state.trackIds == 1 and " track" or " tracks") .. " will be rewritten")
			:style(theme:s():text(theme:type("xs")):fg(theme:color("faint")))
	end
	rows[#rows + 1] = div()
		:style(sty():row():h(theme:px(32)):gap(theme:px(8)):align("center"):justify("end"))
		:children({
			ui.button(ctx, { label = "Cancel", onClick = CANCEL, height = theme:px(30), width = theme:px(80) }),
			ui.button(ctx, { label = "Save", onClick = SAVE, variant = "primary", height = theme:px(30), width = theme:px(74) })
		})

	local count = #state.fields
	local height = padding * 2 + theme:px(28) + count * (rowHeight + gap) + theme:px(32) + gap
		+ (state.kind == "album" and theme:px(18) + gap or 0)
	local panel = div()
		:style(
			sty()
				:w(width):h(height):column():pad(padding):gap(gap):radius(theme:radius("md")):bg(theme:color("elevated"))
				:border(theme:px(1), theme:color("border")):shadow(0, theme:px(14), theme:px(36), "#00000099")
		):onClick({ type = "keep" })
		:children(rows)

	return div()
		:style(
			sty()
				:size(window.width, window.height):offset(0, 0):z(132):column():align("center"):justify("center")
				:bg(theme:color("overlay"))
		):onClick({ type = "dismiss" }):children({ panel })
end

return editor
