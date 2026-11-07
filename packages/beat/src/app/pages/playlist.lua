-- The playlist screen: the collection view with its own cover, its kind, and the control
-- that adds more to it.
local wonderland = require("wonderland")
local core = require("beat-core")
local ui = require("beat-ui")
local render = require("beat.app.ui")
local PlaylistArt = require("beat.app.playlist_art")
local collection = require("beat.app.collection_view")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty
local util = core.util

---@type beat.PageSurface
local playlistPage = {}

---@param page beat.PageInstance
---@return string
function playlistPage.key(page)
	return "playlist:" .. tostring(page.id)
end

--- Read from the taxonomy each frame: a page kept in the history outlives the playlist that
--- was deleted while it waited.
---@param app beat.App
---@param page beat.PageInstance
---@param window wonderland.RenderWindow
---@return wonderland.Element
function playlistPage.view(app, page, window)
	local playlist = app.services.collections.taxonomy:playlist(page.id --[[@as number]])
	if playlist == nil then
		return render.empty(app, "Playlist not found", nil, "Playlists",
		{ type = "navigate", page = { kind = "playlists"}})
	end
	---@cast playlist beat.Playlist
	local tracks = PlaylistArt.tracks(app, playlist)
	---@cast tracks beat.Track[]
	local tagNames = {}
	for _, id in ipairs(playlist.tagIds) do
			local tag = app.services.collections.taxonomy.tagById[id]
			if tag ~= nil then tagNames[#tagNames + 1] = tag.name end
		end
	local duration = 0
	for _, track in ipairs(tracks) do duration = duration + track.duration end

	local subtitle = "Playlist"
	if playlist.autoTagId ~= nil then
		subtitle = "Auto playlist"
	elseif playlist.smart and #tagNames > 0 then
		subtitle = "Smart playlist · " .. table.concat(tagNames, playlist.match == "any" and " or " or " · ")
	end

	local current = app.services.playback:current()
	local source = app.services.playback.player.queue and app.services.playback.player.queue.source or nil
	local thisPlaylist = current ~= nil and source == "playlist:" .. tostring(playlist.id)
	local playing = app.services.playback.player:isPlaying()

	local empty = div():style(sty():column():wrel(1.0):h(120):align("center"):justify("center")
	:gap(10)):children({
	ui.icons.element("playlists", app.services.appearance.theme:px(34), app.services.appearance.theme:color("faint")),
	text("This playlist is empty"):style(app.services.appearance.theme:s():text(app.services.appearance.theme:type("lg"))
	:weight("bold"):fg(app.services.appearance.theme:color("text"))),
	text("Use + to add albums, or right-click a track and add it here."):style(
	app.services.appearance.theme:s():text(app.services.appearance.theme:type("sm")):fg(app.services.appearance.theme:color("muted"))),
	})

	return collection.page(app, window, {
	label = "PLAYLIST",
	icons = PlaylistArt.icons(app, playlist),
	cover = function(size) return PlaylistArt.art(app, tracks, size, app.services.appearance.theme:radius("lg"), playlist.name) end,
	title = playlist.name,
	subtitle = subtitle,
	meta = util.count(#tracks, "track")
	.. (duration > 0 and (" · " .. util.duration(duration)) or "")
	.. " · " .. PlaylistArt.editedLabel(playlist.updatedAt),
	playAction = thisPlaylist and { type = "togglePlay"}
	or { type = "playPlaylist", id = playlist.id},
	playIcon = playing and thisPlaylist and "pause" or "play",
	shuffleAction = { type = "playPlaylist", id = playlist.id, shuffle = true},
	addAction = { type = "open", overlay = "playlist_adder", playlistId = playlist.id},
	tracks = tracks,
	trackAction = function(track)
		return { type = "playPlaylistTrack", playlistId = playlist.id, trackId = track.id}
	end,
	empty = empty,
	})
end

return playlistPage
