-- The album screen: its cover, its details and its track table. The artist's name opens the
-- artist's page.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local format = require("beat.app.components.helpers.format")
local cover = require("beat.app.components.cover")
local collection = require("beat.app.components.collection")

---@type beat.PageSurface
local albumPage = {}

--- The message a press on the current album's play control sends; the same table every frame.
local TOGGLE_PLAY = { type = "togglePlay" }

--- What a track's row sends when it is clicked, one per track: an album page builds its rows
--- again on every scroll step, and a message the row never changes can be sent again.
---@type table<beat.Track, table>
local trackActions = setmetatable({}, { __mode = "k" })

---@param track beat.Track
---@return table
local function trackAction(track)
	local message = trackActions[track]
	if message == nil then
		message = { type = "playTrack", trackId = track.id, albumId = track.albumId }
		trackActions[track] = message
	end
	return message
end

--- The number a row shows: the track's own, or its place when the library gave it none.
---@param track beat.Track
---@param at number
---@return number
local function trackIndex(track, at)
	return track.number or at
end

--- The things a page for one album sends and draws that do not depend on what is playing now: the
--- cover it opens, the menu under a right-click, the artist's page, the two ways of playing it and
--- the ratings. Kept per album, because a page is built again every frame it is scrolled.
---@class beat.pages.AlbumUi
---@field openCover table
---@field coverMenu table # Open the album's menu where the pointer is
---@field subtitleAction table
---@field playAction table
---@field shuffleAction table
---@field rate fun(stars: number): table
---@field cover fun(size: number): wonderland.Element
---@field trackAction fun(track: beat.Track, at: number): table
---@field trackIndex fun(track: beat.Track, at: number): number
---@field props table

---@type table<beat.Album, beat.pages.AlbumUi>
local albumUi = setmetatable({}, { __mode = "k" })

--- The things one album's page sends and draws, made the first time the album is shown. It is
--- kept apart from the lookup that follows so the frames after the first only read the record:
--- a function declared in the lookup itself is one the trace compiler gives up on, however often
--- the record is already there.
---@param app beat.App
---@param album beat.Album
---@param ratings boolean
---@return beat.pages.AlbumUi
local function buildUi(app, album, ratings)
	local id = album.id
	local artistId = album.artistId
	local found = {
		openCover = { type = "open", overlay = "cover_view", id = id },
		-- The menu opens where the pointer is, which is where a right-click landed: the message
		-- names no place and the page keeps no closure to make one.
		coverMenu = { type = "open", overlay = "menu", menu = "album", id = id },
		subtitleAction = { type = "navigate", page = { kind = "artist", id = artistId } },
		playAction = { type = "playAlbum", id = id },
		shuffleAction = { type = "playAlbum", id = id, shuffle = true },
		rate = |stars| -> { type = "rateAlbum", id = id, stars = stars },
		trackAction = trackAction,
		trackIndex = trackIndex
	} --[[@as beat.pages.AlbumUi]]
	found.cover = |size| -> cover
		.view(
			app,
			{
				album = album,
				size = size,
				radius = app.services.appearance.theme:radius("lg"),
				glow = true,
				sheen = true
			}
		)
		:onClick(found.openCover)
	found.props = {
		window = nil,
		label = album.single and "SINGLE" or "ALBUM",
		cover = found.cover,
		coverMenu = found.coverMenu,
		title = album.title,
		subtitle = album.artist,
		subtitleAction = found.subtitleAction,
		meta = (album.year and (album.year .. " · ") or "") .. format.count(#album.tracks, "track") .. " · " .. format.duration(
			album.duration
		),
		playAction = found.playAction,
		playIcon = "play",
		titleOnly = true,
		ratings = ratings,
		phoneHero = true,
		shuffleAction = found.shuffleAction,
		rating = nil,
		onRate = ratings and found.rate or nil,
		tracks = album.tracks,
		trackAction = found.trackAction,
		trackIndex = found.trackIndex
	}
	return found
end

---@param app beat.App
---@param album beat.Album
---@param ratings boolean
---@return beat.pages.AlbumUi
local function uiFor(app, album, ratings)
	local found = albumUi[album]
	if found ~= nil then return found end
	found = buildUi(app, album, ratings)
	albumUi[album] = found
	return found
end

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
	local ratings = app.registry:hasPlugin("ratings")
	local kept = uiFor(app, album, ratings)
	local props = kept.props
	props.window = window
	props.playAction = thisAlbum and TOGGLE_PLAY or kept.playAction
	props.playIcon = playing and thisAlbum and "pause" or "play"
	props.rating = ratings and app.services.collections.taxonomy:albumRating(album.key) or nil
	return collection.view(app, props)
end

return albumPage
