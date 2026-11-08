-- The album screen: its cover, its details and its track table. The artist's name opens the
-- artist's page.
local format = require("beat.app.components.helpers.format")
local cover = require("beat.app.components.cover")
local emptyState = require("beat.app.components.empty_state")
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
	local album = library ~= nil and library:album(id) or nil
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
	local library = app.services.library.current
	local album = library ~= nil and library:album(id) or nil
	if album == nil then
		return emptyState.view(app, {
			title = "Album not found",
			copy = "The scan no longer has it.",
			actionLabel = "Library",
			action = { type = "navigate", page = { kind = "library"}},
		})
	end
	local current = app.services.playback:current()
	local thisAlbum = current ~= nil and current.albumId == album.id
	local playing = app.services.playback.player:isPlaying()
	return collection.view(app, {
		window = window,
		label = "ALBUM",
		cover = function(size)
			return cover.view(app, { album = album, size = size, radius = app.services.appearance.theme:radius("lg"), glow = true })
		end,
		coverMenu = function(_, _, _, _, _, windowX, windowY)
			return { type = "open", overlay = "menu", menu = "album", id = album.id, x = windowX, y = windowY}
		end,
		title = album.title,
		subtitle = album.artist,
		subtitleAction = { type = "navigate", page = { kind = "artist", id = album.artistId}},
		meta = (album.year and (album.year .. " · ") or "") .. format.count(#album.tracks, "track")
		.. " · " .. format.duration(album.duration),
		playAction = thisAlbum and { type = "togglePlay"} or { type = "playAlbum", id = album.id},
		playIcon = playing and thisAlbum and "pause" or "play",
		titleOnly = true,
		shuffleAction = { type = "playAlbum", id = album.id, shuffle = true},
		tracks = album.tracks,
		trackAction = function(track)
			return { type = "playTrack", trackId = track.id, albumId = album.id}
		end,
		trackIndex = function(track, at) return track.number or at end,
	})
end

return albumPage
