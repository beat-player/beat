-- Tags and playlists, the sidebar's shortcuts to them, the screens that edit them and the panels
-- that put a track or an album into one. Deleting a playlist is an action here because the menu
-- entry is the only thing that asks for it.
local beat = require("beat")
local collections = require("beat.app.services.collections")
local sidebar = require("beat.app.services.sidebar")

-- Pages and overlays are named by module, not read here: one is read when it is first shown.
local playlistsPage = "beat.app.pages.playlists"
local playlistPage = "beat.app.pages.playlist"

local playlistAdder = "beat.app.overlays.playlist_adder"
local playlistDialog = "beat.app.overlays.playlist_dialog"
local playlistPicker = "beat.app.overlays.playlist_picker"
local tagPicker = "beat.app.overlays.tag_picker"
local tagDialog = "beat.app.overlays.tag_dialog"
local tagDelete = "beat.app.overlays.tag_delete"

return beat.plugin({ name = "collections", version = "1.0.0", author = "beat", description = "Tags and playlists, with ratings' data", requires = { core = "^1.0.0", library = "^1.0.0" }, setup = function(handle)
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

	handle.action({ menu = "track", title = "Tag track", icon = "tag", order = 25, message = |ctx| -> { type = "open", overlay = "tag_picker", kind = "track", id = assert(ctx.track).id } })
	handle.action({ menu = "album", title = "Tag album", icon = "tag", order = 25, message = |ctx| -> { type = "open", overlay = "tag_picker", kind = "album", id = assert(ctx.album).id } })
	handle.action({ menu = "playlist", title = "Delete playlist", icon = "close", order = 10, tone = "danger", message = |ctx| -> { type = "deletePlaylist", id = assert(ctx.playlist).id } })
end })
