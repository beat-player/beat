-- The album screen: its cover, its details and its track table. The artist's name opens the
-- artist's page.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local format = require("beat.app.components.helpers.format")
local cover = require("beat.app.components.cover")
local collection = require("beat.app.components.collection")

---@type beat.PageSurface
local albumPage = {}

--- Two album pages are different pages even with the same cover: the scroll and the back
--- stack tell them apart by this, not by the kind.
---@param page beat.PageInstance
---@return string
function albumPage.key(page)
	return "album:" .. tostring(page.id)
end

--- Space, or the bar's play, with nothing queued: on an album page that means this album, which
--- only the page knows. With a queue it is the player's pause, and goes on to playback.
---@param app beat.App
---@param page beat.PageInstance
---@param message beat.Message
function albumPage.update(app, page, message)
	if message.type ~= "togglePlay" or app.services.playback.player.queue ~= nil then return false end
	local id = assert(page.id)
	local library = app.services.library.current
	local album = library ~= nil ? (library:album(id)) : nil
	if album == nil then return false end
	app.services.playback.player:playAlbum(album)
	app:refresh()
	return true
end

--- Read from the library each frame: a page kept in the history outlives the scan that made
--- it, and says so rather than showing an album that is gone.
---@param app beat.App
---@param page beat.PageInstance
---@param window wonderland.RenderWindow
---@return wonderland.Element
function albumPage.view(app, page, window)
	local id = assert(page.id)
	local ctx = app:ui(window)
	local library = app.services.library.current
	local album = library ~= nil ? (library:album(id)) : nil
	if album == nil then
		return ui.emptyState(
			ctx,
			{
				title = "Album not found",
				copy = "The scan no longer has it.",
				actionLabel = "Library",
				action = { type = "navigate", page = { kind = "library" } }
			}
		)
	end
	local current = app.services.playback:current()
	local thisAlbum = current?.albumId == album.id
	local playing = app.services.playback.player:isPlaying()
	return collection.view(
		app,
		{
			window = window,
			label = "ALBUM",
			cover = |size| -> cover.view(
				app,
				{ album = album, size = size, radius = app.services.appearance.theme:radius("lg"), glow = true }
			),
			coverMenu = |_, _, _, _, _, windowX, windowY| -> {
				type = "open",
				overlay = "menu",
				menu = "album",
				id = album.id,
				x = windowX,
				y = windowY
			},
			title = album.title,
			subtitle = album.artist,
			subtitleAction = { type = "navigate", page = { kind = "artist", id = album.artistId } },
			meta = (album.year and (album.year .. " · ") or "") .. format.count(#album.tracks, "track") .. " · " .. format.duration(
				album.duration
			),
			playAction = thisAlbum ? { type = "togglePlay" } : { type = "playAlbum", id = album.id },
			playIcon = playing and thisAlbum ? "pause" : "play",
			titleOnly = true,
			ratings = true,
			shuffleAction = { type = "playAlbum", id = album.id, shuffle = true },
			rating = app.services.collections.taxonomy:albumRating(album.key),
			onRate = |stars| -> { type = "rateAlbum", id = album.id, stars = stars },
			tracks = album.tracks,
			trackAction = |track| -> { type = "playTrack", trackId = track.id, albumId = album.id },
			trackIndex = |track, at| -> track.number or at
		}
	)
end

return albumPage
