-- The library the app browses: what a scan found, the covers and search built on it, every screen
-- that lists it, and the menu entries that start or queue what is on one of those screens.
local beat = require("beat")
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

return beat.plugin({ name = "library", version = "1.0.0", requires = { core = "^1.0.0" }, setup = function(handle)
	handle.service("library", library)
	handle.service("covers", covers)
	handle.service("scan", scan)
	handle.service("search", search)

	handle.page("home", homePage)
	handle.page("library", libraryPage)
	handle.page("folders", foldersPage)
	handle.page("search", searchPage)
	handle.page("searchAll", searchAllPage)
	handle.page("artist", artistPage)
	handle.page("album", albumPage)

	handle.overlay("sort_menu", sortMenu)

	handle.action({ menu = "album", title = "Play album", order = 10, message = |ctx| -> ctx.message.playAlbum(assert(ctx.album).id, true) })
	handle.action({ menu = "album", title = "Add to playlist", order = 20, message = |ctx| -> ctx.message.openPlaylistPicker("album", assert(ctx.album).id) })
	handle.action({ menu = "album", title = "Play next", order = 30, message = |ctx| -> ctx.message.queueAlbum(assert(ctx.album).id, true) })
	handle.action({ menu = "album", title = "Add to queue", order = 40, message = |ctx| -> ctx.message.queueAlbum(assert(ctx.album).id) })

	handle.action({ menu = "track", title = "Play now", order = 10, message = |ctx| -> ctx.message.playTrack(assert(ctx.track).id, nil, nil, true) })
	handle.action({ menu = "track", title = "Add to playlist", order = 20, message = |ctx| -> ctx.message.openPlaylistPicker("track", assert(ctx.track).id) })
end })
