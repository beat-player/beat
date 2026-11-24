-- The playlist screen: the collection view with its own cover, its kind, and -- for a list that
-- can grow by hand -- the control that adds more to it. A built-in smart list is read-only.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local format = require("beat.app.components.helpers.format")
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
	local ctx = app:ui(window)
	local playlist = app.services.collections.taxonomy:playlist(page.id --[[@as number]] )
	if playlist == nil then
		return ui.emptyState(
			ctx,
			{
				title = "Playlist not found",
				actionLabel = "Playlists",
				action = { type = "navigate", page = { kind = "playlists" } }
			}
		)
	end
	local tracks = PlaylistArt.tracks(app, playlist)
	local builtin = playlist.builtin == true
	local tagNames = {}
	for _, id in ipairs(playlist.tagIds) do
		local tag = app.services.collections.taxonomy.tagById[id]
		if tag ~= nil then tagNames[#tagNames + 1] = tag.name end
	end
	local duration = 0
	for _, track in ipairs(tracks) do duration += track.duration end

	-- A built-in list's name already says what it holds, so it has no line under it.
	local subtitle = not builtin and "Playlist" or nil
	if not builtin and playlist.autoTagId ~= nil then
		subtitle = "Auto playlist"
	elseif not builtin and playlist.smart and #tagNames > 0 then
		subtitle = "Smart playlist · " .. table.concat(tagNames, playlist.match == "any" ? " or " : " · ")
	end

	local current = app.services.playback:current()
	local queue = app.services.playback.player.queue
	local source = queue?.source
	local thisPlaylist = current ~= nil and source == "playlist:" .. tostring(playlist.id)
	local playing = app.services.playback.player:isPlaying()

	local emptyTitle = builtin and "Nothing in this list yet" or "This playlist is empty"
	local emptyCopy = builtin
		and "Play some music, or add files to your library, and this list fills itself."
		or "Use + to add albums, or right-click a track and add it here."
	local empty = div()
		:style(sty():column():wrel(1.0):h(120):align("center"):justify("center"):gap(10))
		:children(
			{
				ui.icon(
					ctx,
					{
						name = "playlists",
						size = app.services.appearance.theme:px(34),
						colour = app.services.appearance.theme:color("faint")
					}
				),
				text(emptyTitle)
					:style(
						app.services.appearance.theme:s()
							:text(app.services.appearance.theme:type("lg")):weight("bold"):fg(app.services.appearance.theme:color("text"))
					),
				text(emptyCopy)
					:style(
						app.services.appearance.theme:s()
							:text(app.services.appearance.theme:type("sm")):fg(app.services.appearance.theme:color("muted"))
					)
			}
		)

	local meta = format.count(#tracks, "track") .. (duration > 0 and (" · " .. format.duration(duration)) or "")
	if not builtin then meta = meta .. " · " .. PlaylistArt.editedLabel(playlist.updatedAt) end

	return collection.view(
		app,
		{
			window = window,
			label = builtin ? "SMART PLAYLIST" : "PLAYLIST",
			icons = builtin ? nil : PlaylistArt.icons(app, { playlist = playlist, ui = ctx }),
			cover = |size| -> PlaylistArt.view(
				app,
				{
					tracks = tracks,
					size = size,
					radius = app.services.appearance.theme:radius("lg"),
					name = playlist.name,
					ui = ctx
				}
			),
			title = playlist.name,
			subtitle = subtitle,
			meta = meta,
			playAction = thisPlaylist ? { type = "togglePlay" } : { type = "playPlaylist", id = playlist.id },
			playIcon = playing and thisPlaylist ? "pause" : "play",
			shuffleAction = { type = "playPlaylist", id = playlist.id, shuffle = true },
			addAction = builtin ? nil : { type = "open", overlay = "playlist_adder", playlistId = playlist.id },
			tracks = tracks,
			trackAction = |track| -> { type = "playPlaylistTrack", playlistId = playlist.id, trackId = track.id },
			empty = empty
		}
	)
end

return playlistPage
