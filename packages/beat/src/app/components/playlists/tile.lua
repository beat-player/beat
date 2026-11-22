-- A playlist as the playlists page shows it: its mosaic, its name, how many tracks it holds, and
-- the two ways into it without opening it first. The New playlist tile shares the shape, so the
-- first grid on the page reads as one thing whatever the listener owns.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local format = require("beat.app.components.helpers.format")
local PlaylistArt = require("beat.app.components.playlist_art")
local cover = require("beat.app.components.cover")
local styles = require("beat.app.components.helpers.styles")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local tile = {}

---@class beat.components.playlists.TileProps
---@field width number
---@field playlist beat.Playlist
---@field tracks beat.Track[]
---@field mobile boolean
---@field ui beat.ui.Context
---@field onOpen any
---@field onPlay any
---@field onShuffle any
---@field onMenu fun(...): any? # The right-click menu at where it happened; built-in lists have none

---@class beat.components.playlists.NewTileProps
---@field width number
---@field mobile boolean
---@field ui beat.ui.Context
---@field onCreate any

---@class beat.components.playlists.TileStyles
---@field card wonderland.StyleBuilder
---@field cardHover wonderland.StyleBuilder
---@field art wonderland.StyleBuilder
---@field artNew wonderland.StyleBuilder
---@field block wonderland.StyleBuilder
---@field name wonderland.StyleBuilder
---@field meta wonderland.StyleBuilder
---@field actions wonderland.StyleBuilder
---@field play wonderland.StyleBuilder
---@field playHover wonderland.StyleBuilder
---@field shuffle wonderland.StyleBuilder
---@field shuffleHover wonderland.StyleBuilder
---@field blockHeight number
---@field actionHeight number
---@field iconSize number

--- The tile's cover plus the block under it. The block's height comes from the type it sets, so
--- a type scale change moves every row of the grid together rather than cutting a line in half.
---@param app beat.App
---@param props { width: number, mobile: boolean }
---@return number
function tile.height(app, props)
	local theme = app.services.appearance.theme
	local nameHeight = math.floor(theme:type("base") * 1.35)
	local metaHeight = math.floor(theme:type("sm") * 1.35)
	local actionHeight = theme:px(props.mobile and 44 or 36)
	local padTop = theme:px(10)
	local gap = theme:px(4)
	return props.width + padTop + nameHeight + gap + metaHeight + gap + actionHeight
end

---@param app beat.App
---@param width number
---@param mobile boolean
---@return beat.components.playlists.TileStyles
local function tileStyles(app, width, mobile)
	local theme = app.services.appearance.theme
	local nameHeight = math.floor(theme:type("base") * 1.35)
	local metaHeight = math.floor(theme:type("sm") * 1.35)
	local actionHeight = theme:px(mobile and 44 or 36)
	local padTop = theme:px(10)
	local gap = theme:px(4)
	local blockHeight = padTop + nameHeight + gap + metaHeight + gap + actionHeight
	local height = width + blockHeight
	local radius = theme:radius("md")

	local function card()
		return sty():w(width):h(height):column()
	end

	return {
		card = card(),
		cardHover = card():bright(1.08),
		art = sty():size(width, width),
		artNew = sty()
			:size(width, width):radius(radius):bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
			:align("center"):justify("center"),
		block = sty():column():wrel(1.0):h(blockHeight):pad(padTop, 0, 0, 0):gap(gap),
		name = theme:s():wrel(1.0):h(nameHeight):text(theme:type("base")):weight("semibold"):fg(theme:color("text")):ellipsis(),
		meta = theme:s():wrel(1.0):h(metaHeight):text(theme:type("sm")):fg(theme:color("muted")):ellipsis(),
		actions = sty():row():wrel(1.0):h(actionHeight):gap(theme:px(8)):align("center"),
		play = sty()
			:size(actionHeight, actionHeight):radius(theme:radius("full")):bg(theme:color("accent"))
			:align("center"):justify("center"),
		playHover = sty()
			:size(actionHeight, actionHeight):radius(theme:radius("full")):bg(theme:color("accent"))
			:align("center"):justify("center"):bright(1.10),
		shuffle = sty():size(actionHeight, actionHeight):radius(theme:radius("full")):align("center"):justify("center"),
		shuffleHover = sty()
			:size(actionHeight, actionHeight):radius(theme:radius("full")):bg(theme:color("hover"))
			:align("center"):justify("center"),
		blockHeight = blockHeight,
		actionHeight = actionHeight,
		iconSize = theme:px(mobile and 20 or 16)
	}
end

--- The label under a playlist's name: how many tracks the list holds right now.
---@param tracks beat.Track[]
---@return string
local function trackCount(tracks)
	return format.count(#tracks, "track")
end

--- The tile's square: the list's first covers where the library has pictures, and the
--- playlist's initials only when there are none. A cell whose picture is still being decoded
--- stays black rather than putting a second set of letters over the art.
---@param app beat.App
---@param props beat.components.playlists.TileProps
---@return wonderland.Element
local function artView(app, props)
	local theme = app.services.appearance.theme
	local size = props.width
	local radius = theme:radius("md")
	local library = app.services.library.current
	local picked = PlaylistArt.mosaicTracks(props.tracks)
	local single = #picked <= 1
	local cellSize = single and size or math.floor(size / 2)
	local slots = single and 1 or 4
	---@type (beat.Album?)[]
	local albums = {}
	local pictures = 0
	for slot = 1, slots do
		local track = picked[slot]
		local album = track ~= nil and library ~= nil ? (library:album(track.albumId)) : nil
		albums[slot] = album
		if album ~= nil and app.services.covers:request(album, cellSize) ~= nil then pictures += 1 end
	end

	if pictures == 0 then
		return PlaylistArt.view(
			app,
			{ tracks = {}, size = size, radius = radius, name = props.playlist.name, ui = props.ui }
		)
	end

	local root = div():style(sty():column():size(size, size):radius(radius):bg("#000000")):clip()
	local function cellAt(slot)
		local album = albums[slot]
		if album ~= nil and app.services.covers:request(album, cellSize) ~= nil then
			return cover.view(app, { album = album, size = cellSize, radius = 0 })
		end
		return div():style(sty():size(cellSize, cellSize):bg("#000000"))
	end
	if single then
		root:children({ cellAt(1) })
		return root
	end
	root:children(
		{
			div():style(sty():row():h(cellSize)):children({ cellAt(1), cellAt(2) }),
			div():style(sty():row():h(cellSize)):children({ cellAt(3), cellAt(4) })
		}
	)
	return root
end

---@param app beat.App
---@param props beat.components.playlists.TileProps
---@return wonderland.Element
function tile.view(app, props)
	local theme = app.services.appearance.theme
	local ctx = props.ui
	local playlist = props.playlist
	local width = props.width
	local s = styles.of(theme, "playlistsTile", tostring(width) .. (props.mobile and "m" or "d")) --[[@as beat.components.playlists.TileStyles]]
	if s.card == nil then
		local built = tileStyles(app, width, props.mobile)
		for key, value in pairs(built) do s[key] = value end
	end

	local blockChildren = {
		text(playlist.name):style(s.name),
		text(trackCount(props.tracks)):style(s.meta)
	}

	-- An empty list has nothing to play or shuffle, so the controls are not drawn at all; the
	-- count above them stays to say why.
	if #props.tracks > 0 then
		local queue = app.services.playback.player.queue
		local source = queue?.source
		local thisList = source == "playlist:" .. tostring(playlist.id)
		local playing = app.services.playback.player:isPlaying()
		local onPlay = thisList and { type = "togglePlay" } or props.onPlay
		local playIcon = thisList and playing and "pause" or "play"

		local play = div()
			:style(s.play):hover(s.playHover):onClick(onPlay)
			:children(ui.icon(ctx, { name = playIcon, size = s.iconSize, colour = theme.accentInk }))

		-- The shuffle button says what it does while there is room for the word; on a tile too
		-- narrow for it the glyph is the same size as the play control beside it.
		local shuffleWidth = width - s.actionHeight - theme:px(8)
		local shuffle
		if shuffleWidth >= theme:px(96) then
			shuffle = ui.button(
				ctx,
				{
					label = "Shuffle",
					icon = "shuffle",
					variant = "secondary",
					height = s.actionHeight,
					width = shuffleWidth,
					onClick = props.onShuffle
				}
			)
		else
			shuffle = div()
				:style(s.shuffle):hover(s.shuffleHover):onClick(props.onShuffle)
				:children(ui.icon(ctx, { name = "shuffle", size = s.iconSize, colour = theme:color("muted") }))
		end

		blockChildren[#blockChildren + 1] = div():style(s.actions):children({ play, shuffle })
	end

	local root = div()
		:style(s.card):hover(s.cardHover):onClick(props.onOpen)
		:children(
			{
				div():style(s.art):children({ artView(app, props) }),
				div():style(s.block):children(blockChildren)
			}
		)
	if props.onMenu ~= nil then root:onContextMenu(props.onMenu) end
	return root
end

--- The first tile of the listener's own row: an empty square to fill, which opens the dialog
--- that starts a playlist rather than a page that does not exist yet.
---@param app beat.App
---@param props beat.components.playlists.NewTileProps
---@return wonderland.Element
function tile.newPlaylist(app, props)
	local theme = app.services.appearance.theme
	local ctx = props.ui
	local width = props.width
	local s = styles.of(theme, "playlistsNewTile", tostring(width) .. (props.mobile and "m" or "d")) --[[@as beat.components.playlists.TileStyles]]
	if s.card == nil then
		local built = tileStyles(app, width, props.mobile)
		for key, value in pairs(built) do s[key] = value end
	end

	return div()
		:style(s.card):hover(s.cardHover):onClick(props.onCreate)
		:children(
			{
				div()
					:style(s.artNew)
					:children(ui.icon(ctx, { name = "add", size = theme:px(props.mobile and 36 or 30), colour = theme:color("muted") })),
				div()
					:style(s.block)
					:children(
						{
							text("New playlist"):style(s.name),
							text("Make your own"):style(s.meta),
							div()
								:style(s.actions)
								:children(
									{
										ui.button(
											ctx,
											{
												label = "Create",
												icon = "add",
												variant = "secondary",
												height = s.actionHeight,
												width = width,
												onClick = props.onCreate
											}
										)
									}
								)
						}
					)
			}
		)
end

return tile
