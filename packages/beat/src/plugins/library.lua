-- The library the app browses: what a scan found, the covers and search built on it, every screen
-- that lists it, and the menu entries that start or queue what is on one of those screens.
local library = require("beat.app.services.library")
local covers = require("beat.app.services.covers")
local scan = require("beat.app.services.scan")
local search = require("beat.app.services.search")

local homePage = require("beat.app.pages.home")
local libraryPage = require("beat.app.pages.library")
local foldersPage = require("beat.app.pages.folders")
local searchPage = require("beat.app.pages.search")
local searchAllPage = require("beat.app.pages.search_all")
local artistPage = require("beat.app.pages.artist")
local albumPage = require("beat.app.pages.album")

local sortMenu = require("beat.app.overlays.sort_menu")

return {
	name = "library",
	version = "1.0.0",
	requires = { core = "^1.0.0" },
	setup = function(beat)
		beat.service("library", library)
		beat.service("covers", covers)
		beat.service("scan", scan)
		beat.service("search", search)

		beat.page("home", homePage)
		beat.page("library", libraryPage)
		beat.page("folders", foldersPage)
		beat.page("search", searchPage)
		beat.page("searchAll", searchAllPage)
		beat.page("artist", artistPage)
		beat.page("album", albumPage)

		beat.overlay("sort_menu", sortMenu)

		beat.action({
			menu = "album",
			title = "Play album",
			order = 10,
			message = function(ctx) return { type = "playAlbum", id = ctx.album.id, restart = true } end,
		})
		beat.action({
			menu = "album",
			title = "Add to playlist",
			order = 20,
			message = function(ctx)
				return { type = "open", overlay = "playlist_picker", kind = "album", id = ctx.album.id }
			end,
		})
		beat.action({
			menu = "album",
			title = "Play next",
			order = 30,
			message = function(ctx) return { type = "queueAlbum", id = ctx.album.id, next = true } end,
		})
		beat.action({
			menu = "album",
			title = "Add to queue",
			order = 40,
			message = function(ctx) return { type = "queueAlbum", id = ctx.album.id } end,
		})

		beat.action({
			menu = "track",
			title = "Play now",
			order = 10,
			message = function(ctx) return { type = "playTrack", trackId = ctx.track.id, restart = true } end,
		})
		beat.action({
			menu = "track",
			title = "Add to playlist",
			order = 20,
			message = function(ctx)
				return { type = "open", overlay = "playlist_picker", kind = "track", id = ctx.track.id }
			end,
		})
	end,
}
