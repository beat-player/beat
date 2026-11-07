-- The album screen: its cover, its details and its track table. The artist's name opens the
-- artist's page.
local core = require("beat-core")
local render = require("beat.app.ui")
local collection = require("beat.app.collection_view")

local util = core.util

---@type beat.PageSurface
local albumPage = {}

--- Two album pages are different pages even with the same cover: the scroll and the back
--- stack tell them apart by this, not by the kind.
---@param page beat.PageInstance
---@return string
function albumPage.key(page)
	return "album:" .. tostring(page.id)
end

--- Read from the library each frame: a page kept in the history outlives the scan that made
--- it, and says so rather than showing an album that is gone.
---@param app beat.App
---@param page beat.PageInstance
---@param window wonderland.RenderWindow
---@return wonderland.Element
function albumPage.view(app, page, window)
	local album = app.library ~= nil and app.library:album(page.id) or nil
	if album == nil then
		return render.empty(app, "Album not found", "The scan no longer has it.", "Library",
		{ type = "navigate", page = { kind = "library"}})
	end
	---@cast album beat.Album
	local thisAlbum = app:currentTrack() ~= nil and app:currentTrack().albumId == album.id
	local playing = app.player:isPlaying()
	return collection.page(app, window, {
	label = "ALBUM",
	cover = function(size) return render.cover(app, album, size, app.theme:radius("lg"), true) end,
	coverMenu = function(_, _, _, _, _, windowX, windowY)
		return { type = "open", overlay = "album_menu", id = album.id, x = windowX, y = windowY}
	end,
	title = album.title,
	subtitle = album.artist,
	subtitleAction = { type = "navigate", page = { kind = "artist", id = album.artistId}},
	meta = (album.year and (album.year .. " · ") or "") .. util.count(#album.tracks, "track")
	.. " · " .. util.duration(album.duration),
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
