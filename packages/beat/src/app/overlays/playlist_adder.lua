-- The panel that adds albums to a playlist, opened from the playlist's own +.
local wonderland = require("wonderland")
local cover = require("beat.app.components.cover")
local field = require("beat.app.components.field")
local iconButton = require("beat.app.components.icon_button")
local metrics = require("beat.app.components.helpers.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.PlaylistAdderState
---@field playlistId number
---@field query string

---@class beat.PlaylistAdderOverlay: beat.OverlaySurface
local playlistAdder = {}

---@param params { playlistId: number }
---@param app beat.App
function playlistAdder.new(app, params)
	local playlist = app.services.collections.taxonomy:playlist(params.playlistId)
	if playlist == nil or app.services.library.current == nil then return nil end
	-- The search field is where typing goes the moment the panel opens.
	app:focusField("playlistAddSearch")
	---@type beat.PlaylistAdderState
	return { playlistId = playlist.id, query = ""}
end

---@param app beat.App
function playlistAdder.close(app)
	app:focusField(nil)
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.PlaylistAdderState>
---@param message beat.Message
function playlistAdder.update(app, overlay, message)
	local state = overlay.state
	if message.type == "playlistAdderQuery" then
		state.query = message.value or ""
		app:refresh()
		return true
	elseif message.type == "playlistAddAlbum" then
		local playlist = app.services.collections.taxonomy:playlist(state.playlistId)
		local library = app.services.library.current
		local album = library ~= nil ? (library:album(tonumber(message.id) or 0)) : nil
		if playlist ~= nil and album ~= nil then
			app.services.collections.taxonomy:setPlaylistAlbum(playlist, album)
			app.services.collections:save()
			app.services.toasts:show("Added " .. album.title .. " to " .. playlist.name)
		end
		app:refresh()
		return true
	end
	return false
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
	local panelWidth = metrics.panelWidth(app, window, 520)
	local rowWidth = panelWidth - theme:px(32)
	---@type beat.Album[]
	local albums
	if state.query == "" then
		albums = {}
		for at = 1, math.min(8, #library.albums) do albums[#albums + 1] = library.albums[at] end
	else
		albums = library:search(state.query)
	end
	local rows = {}
	for at = 1, math.min(8, #albums) do
		local album = albums[at]
		rows[#rows + 1] = div():style(sty():row():wrel(1.0):h(theme:px(42)):gap(theme:px(10))
		:pad(0, theme:px(6), 0, theme:px(6)):align("center"):radius(theme:radius("sm")))
		:hover(sty():row():wrel(1.0):h(theme:px(42)):gap(theme:px(10)):pad(0, theme:px(6),
		0, theme:px(6)):align("center"):radius(theme:radius("sm")):bg(theme:color("hover")))
		:onClick({ type = "playlistAddAlbum", id = album.id})
		:children({
			cover.view(app, { album = album, size = theme:px(32), radius = theme:radius("sm") }),
			div():style(sty():column():w(rowWidth - theme:px(78)):gap(0)):children({
				text(album.title):style(theme:s():wrel(1.0):text(theme:type("sm")):weight("semibold")
				:fg(theme:color("text")):ellipsis()),
				text(album.artist):style(theme:s():wrel(1.0):text(theme:type("xs")):fg(theme:color("muted"))
				:ellipsis()),
			}),
			iconButton.view(app, { name = "add", size = theme:px(26), onClick = { type = "playlistAddAlbum", id = album.id} }),
		})
	end

	local panelHeight = theme:px(520)
	local panel = div()
	:style(sty():w(panelWidth):h(panelHeight):column():pad(theme:px(16)):gap(theme:px(10))
	:radius(theme:radius("lg")):bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(16), theme:px(42), "#00000080"))
	:onClick({ type = "keep" })
	:children({
		div():style(sty():row():wrel(1.0):h(theme:px(28)):gap(theme:px(8)):align("center")):children({
			text("Add to " .. playlist.name):style(theme:s():w(rowWidth - theme:px(28)):text(theme:type("lg"))
			:weight("bold"):fg(theme:color("text")):ellipsis()),
			iconButton.view(app, { name = "close", size = theme:px(28), onClick = { type = "dismiss"} }),
		}),
		field.view(app, {
			name = "playlistAddSearch",
			value = state.query,
			placeholder = "Search albums",
			oninput = |value| -> { type = "playlistAdderQuery", value = value},
			onsubmit = || -> nil,
		}),
		div():style(sty():column():wrel(1.0):h(theme:px(8 * 44)):gap(theme:px(2))):children(rows),
		text(#albums > 8 ? "Showing the first 8; search to narrow the list." : "Click an album to add every track in it."):style((theme:s()):text((theme:type("xs")))
		:fg(theme:color("faint"))),
	})

	return div():style(sty():fill():offset(0, 0):z(122):column():align("center"):justify("center")
	:bg(theme:color("overlay"))):onClick({ type = "dismiss" }):children({ panel})
end

return playlistAdder
