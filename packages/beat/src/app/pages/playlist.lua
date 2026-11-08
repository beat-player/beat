-- The playlist screen: the collection view with its own cover, its kind, and the control
-- that adds more to it.
local wonderland = require("wonderland")
local format = require("beat.app.components.helpers.format")
local icon = require("beat.app.components.icon")
local emptyState = require("beat.app.components.empty_state")
local PlaylistArt = require("beat.app.components.playlist_art")
local collection = require("beat.app.components.collection")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

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
		return emptyState.view(app, {
			title = "Playlist not found",
			actionLabel = "Playlists",
			action = { type = "navigate", page = { kind = "playlists"}},
		})
	end
	local tracks = PlaylistArt.tracks(app, playlist)
	local tagNames = {}
	for _, id in ipairs(playlist.tagIds) do
		local tag = app.services.collections.taxonomy.tagById[id]
		if tag ~= nil then tagNames[#tagNames + 1] = tag.name end
	end
	local duration = 0
	for _, track in ipairs(tracks) do duration += track.duration end

	local subtitle = "Playlist"
	if playlist.autoTagId ~= nil then
		subtitle = "Auto playlist"
	elseif playlist.smart and #tagNames > 0 then
		subtitle = "Smart playlist · " .. table.concat(tagNames, playlist.match == "any" ? " or " : " · ")
	end

	local current = app.services.playback:current()
	local queue = app.services.playback.player.queue
	local source = queue?.source
	local thisPlaylist = current ~= nil and source == "playlist:" .. tostring(playlist.id)
	local playing = app.services.playback.player:isPlaying()

	local empty = div():style(sty():column():wrel(1.0):h(120):align("center"):justify("center")
	:gap(10)):children({
		icon.view(app, { name = "playlists", size = app.services.appearance.theme:px(34),
			colour = app.services.appearance.theme:color("faint") }),
		text("This playlist is empty"):style(app.services.appearance.theme:s():text(app.services.appearance.theme:type("lg"))
		:weight("bold"):fg(app.services.appearance.theme:color("text"))),
		text("Use + to add albums, or right-click a track and add it here."):style(
		app.services.appearance.theme:s():text(app.services.appearance.theme:type("sm")):fg(app.services.appearance.theme:color("muted"))),
	})

	return collection.view(app, {
		window = window,
		label = "PLAYLIST",
		icons = PlaylistArt.icons(app, { playlist = playlist }),
		cover = |size| -> PlaylistArt.view(app, {
				tracks = tracks,
				size = size,
				radius = app.services.appearance.theme:radius("lg"),
				name = playlist.name,
			}),
		title = playlist.name,
		subtitle = subtitle,
		meta = format.count(#tracks, "track")
		.. (duration > 0 and (" · " .. format.duration(duration)) or "")
		.. " · " .. PlaylistArt.editedLabel(playlist.updatedAt),
		playAction = thisPlaylist ? { type = "togglePlay"} : { type = "playPlaylist", id = playlist.id},
		playIcon = playing and thisPlaylist ? "pause" : "play",
		shuffleAction = { type = "playPlaylist", id = playlist.id, shuffle = true},
		addAction = { type = "open", overlay = "playlist_adder", playlistId = playlist.id},
		tracks = tracks,
		trackAction = |track| -> { type = "playPlaylistTrack", playlistId = playlist.id, trackId = track.id},
		empty = empty,
	})
end

return playlistPage
