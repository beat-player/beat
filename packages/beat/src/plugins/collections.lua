-- Tags and playlists, the sidebar's shortcuts to them, the screens that edit them and the panels
-- that put a track or an album into one. Deleting a playlist is an action here because the menu
-- entry is the only thing that asks for it.
local beat = require("beat")
local collections = require("beat.app.services.collections")
local sidebar = require("beat.app.services.sidebar")

local playlistsPage = require("beat.app.pages.playlists")
local playlistPage = require("beat.app.pages.playlist")

local playlistAdder = require("beat.app.overlays.playlist_adder")
local playlistDialog = require("beat.app.overlays.playlist_dialog")
local playlistPicker = require("beat.app.overlays.playlist_picker")
local tagPicker = require("beat.app.overlays.tag_picker")
local tagDialog = require("beat.app.overlays.tag_dialog")
local tagDelete = require("beat.app.overlays.tag_delete")

return beat.plugin({ name = "collections", version = "1.0.0", requires = { core = "^1.0.0", library = "^1.0.0" }, setup = function(handle)
	handle.service("collections", collections)
	handle.service("sidebar", sidebar)

	handle.page("playlists", playlistsPage)
	handle.page("playlist", playlistPage)

	handle.overlay("playlist_adder", playlistAdder)
	handle.overlay("playlist_dialog", playlistDialog)
	handle.overlay("playlist_picker", playlistPicker)
	handle.overlay("tag_picker", tagPicker)
	handle.overlay("tag_dialog", tagDialog)
	handle.overlay("tag_delete", tagDelete)

	handle.action({ menu = "playlist", title = "Delete playlist", order = 10, tone = "danger", message = |ctx| -> ctx.message.deletePlaylist(assert(ctx.playlist).id) })
end })
