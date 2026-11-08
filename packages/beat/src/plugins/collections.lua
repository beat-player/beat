-- Tags and playlists, the sidebar's shortcuts to them, the screens that edit them and the panels
-- that put a track or an album into one. Deleting a playlist is an action here because the menu
-- entry is the only thing that asks for it.
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

return {
	name = "collections",
	version = "1.0.0",
	requires = { core = "^1.0.0", library = "^1.0.0" },
	setup = function(beat)
		beat.service("collections", collections)
		beat.service("sidebar", sidebar)

		beat.page("playlists", playlistsPage)
		beat.page("playlist", playlistPage)

		beat.overlay("playlist_adder", playlistAdder)
		beat.overlay("playlist_dialog", playlistDialog)
		beat.overlay("playlist_picker", playlistPicker)
		beat.overlay("tag_picker", tagPicker)
		beat.overlay("tag_dialog", tagDialog)
		beat.overlay("tag_delete", tagDelete)

		beat.action({
			menu = "playlist",
			title = "Delete playlist",
			order = 10,
			tone = "danger",
			message = function(ctx) return { type = "deletePlaylist", id = ctx.playlist.id } end,
		})
	end,
}
