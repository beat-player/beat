-- Where a track or a whole album goes: one row per playlist, with how many tracks it would hold.
local wonderland = require("wonderland")
local format = require("beat.app.components.helpers.format")
local metrics = require("beat.app.components.helpers.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.PlaylistPickerState
---@field kind "album"|"track"
---@field id number

---@class beat.PlaylistPickerOverlay: beat.OverlaySurface
local playlistPicker = {}

---@param params { kind: "album"|"track", id: number }
---@param app beat.App
function playlistPicker.new(app, params)
	if params.kind ~= "album" and params.kind ~= "track" then return nil end
	if params.id == nil then return nil end
	---@type beat.PlaylistPickerState
	return { kind = params.kind, id = params.id}
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.PlaylistPickerState>
---@param message beat.Message
function playlistPicker.update(app, overlay, message)
	local state = overlay.state
	if message.type ~= "addToPlaylist" then return false end
	local playlist = app.services.collections.taxonomy:playlist(message.playlistId)
	local library = app.services.library.current
	if playlist ~= nil and library ~= nil then
		if state.kind == "album" then
			local album = library:album(state.id)
			if album ~= nil then app.services.collections.taxonomy:setPlaylistAlbum(playlist, album) end
		else
			local track = library:track(state.id)
			if track ~= nil then app.services.collections.taxonomy:setPlaylistTrack(playlist, track.path, true) end
		end
		app.services.collections:save()
		app.services.toasts:show("Added to " .. playlist.name)
	end
	app:close(overlay)
	app:refresh()
	return true
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.PlaylistPickerState>
---@param window wonderland.RenderWindow
function playlistPicker.view(app, overlay, window)
	local state = overlay.state
	local theme = app.services.appearance.theme
	local manual = {}
	for _, playlist in ipairs(app.services.collections.taxonomy.playlists) do
		manual[#manual + 1] = playlist
	end
	local rows = {}
	for _, playlist in ipairs(manual) do
		local count = #app.services.collections:playlistTracks(playlist)
		rows[#rows + 1] = div()
		:style(sty():row():wrel(1.0):h(theme:px(38)):pad(0, theme:px(10), 0, theme:px(10))
		:gap(theme:px(8)):radius(theme:radius("sm")):align("center"):justify("space-between"))
		:hover(sty():row():wrel(1.0):h(theme:px(38)):pad(0, theme:px(10), 0, theme:px(10))
		:gap(theme:px(8)):radius(theme:radius("sm")):align("center"):justify("space-between")
		:bg(theme:color("hover")))
		:onClick({ type = "addToPlaylist", playlistId = playlist.id})
		:children({
			text(playlist.name):style(theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("text"))
			:ellipsis()),
			text(format.count(count, "track")):style(theme:s():text(theme:type("xs")):fg(theme:color("muted"))),
		})
	end
	if #rows == 0 then
		rows[#rows + 1] = text("No playlists yet. Create one on the Playlists page."):style(
		theme:s():wrel(1.0):text(theme:type("xs")):fg(theme:color("muted"))
		)
	end

	local panelHeight = theme:px(20) + theme:px(16) + math.max(0, #rows) * theme:px(38)
	+math.max(0, #rows) * theme:px(4) + theme:px(4)
	local panel = div()
	:style(sty():w(metrics.panelWidth(app, window, 330)):h(panelHeight):column():pad(theme:px(10))
	:gap(theme:px(4)):radius(theme:radius("md"))
	:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(12), theme:px(30), "#00000080"))
	:onClick({ type = "keep"})
	:children({
		text(state.kind == "album" and "Add album to playlist" or "Add track to playlist"):style(
		theme:s():text(theme:type("xs")):weight("bold"):fg(theme:color("muted"))),
	})
	for _, row in ipairs(rows) do panel:children({ row}) end

	return div():style(sty():fill():offset(0, 0):z(121):column():align("center"):justify("center")
	:bg(theme:color("overlay"))):onClick({ type = "dismiss"}):children({ panel})
end

return playlistPicker
