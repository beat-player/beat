-- An album as the shelf shows it: its cover with a play control, and the title block beneath.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local cover = require("beat.app.components.cover")
local styles = require("beat.app.components.helpers.styles")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

-- What the play control sends on the album that is already the current one.
local TOGGLE_PLAY = { type = "togglePlay" }

---@class beat.components.AlbumActions
---@field open table # Navigate to the album's page
---@field play table # Play the album
---@field menu table # Open the album's menu where the pointer is

-- What an album's card or row sends, made once per album rather than once per card per frame.
---@type table<beat.Album, beat.components.AlbumActions>
local actions = setmetatable({}, { __mode = "k" })

local albumCard = {}

--- The props a card is built from, kept per album: every shelf builds its cards again on each
--- frame of a scroll, and only the room the card has and the context it draws in change.
---@type table<beat.Album, { album: beat.Album, cover: table<string, any> }>
local propsOf = setmetatable({}, { __mode = "k" })

--- The messages a card or a row of one album sends, shared by every view that shows the album.
--- A message is read by whoever handles it, never changed, so the same table can be sent again.
---@param album beat.Album
---@return beat.components.AlbumActions
function albumCard.actions(album)
	local found = actions[album]
	if found == nil then
		local id = album.id
		-- The menu opens where the pointer is, and a right-click is what asked for it: the
		-- pointer was set to the click before the handler runs, so the message names no place and
		-- the view keeps no closure to make one. A closure per album is what left the trace
		-- compiler closing an upvalue on the frame that built the shelf.
		found = {
			open = { type = "navigate", page = { kind = "album", id = id } },
			play = { type = "playAlbum", id = id },
			menu = { type = "open", overlay = "menu", menu = "album", id = id }
		}
		actions[album] = found
	end
	return found
end

---@class beat.components.AlbumCardStyles
---@field card wonderland.StyleBuilder
---@field cardHover wonderland.StyleBuilder
---@field art wonderland.StyleBuilder
---@field play wonderland.StyleBuilder
---@field block wonderland.StyleBuilder
---@field title wonderland.StyleBuilder
---@field artist wonderland.StyleBuilder
---@field iconSize number
---@field radius number

---@class beat.components.AlbumCardProps
---@field album beat.Album
---@field width number # The card's width; the cover is square
---@field ui beat.ui.Context
---
---@class beat.components.AlbumCardHeightProps
---@field width number # The card's width

--- The card's cover plus the title block beneath it. The block's height comes from the type it
--- sets, rather than a fixed guess: a type scale change must not cut an artist line in half.
---@param app beat.App
---@param width number
---@return number
function albumCard.height(app, width)
	local theme = app.services.appearance.theme
	return width + theme:px(11) + theme:type("base") + theme:px(2) + theme:type("sm")
end

---@param app beat.App
---@param album beat.Album
---@param width number # The card's width; the cover is square
---@param ctx beat.ui.Context
---@return wonderland.Element
function albumCard.view(app, album, width, ctx)
	local kept = propsOf[album]
	if kept == nil then
		kept = { album = album, cover = { album = album, sheen = true } }
		propsOf[album] = kept
	end
	local theme = app.services.appearance.theme
	local actions = albumCard.actions(album)
	local current = app.services.playback:current()
	local thisAlbum = current?.albumId == album.id
	local playing = thisAlbum and app.services.playback.player:isPlaying()
	-- A click opens the album; the play control plays it, or pauses it while it is the current one.
	local onPlay = thisAlbum and TOGGLE_PLAY or actions.play

	local s = styles.of(theme, "albumCard", width) --[[@as beat.components.AlbumCardStyles]]
	if s.card == nil then
		local height = albumCard.height(app, width)
		local button = theme:px(36)
		local inset = width - theme:px(44)
		s.card = sty():w(width):h(height):column()
		s.cardHover = sty():w(width):h(height):column():bright(1.08)
		s.art = sty():size(width, width)
		s.play = sty()
			:size(button, button):radius(theme:radius("full")):offset(inset, inset):bg(theme:color("accent"))
			:align("center"):justify("center")
		s.block = sty():column():pad(theme:px(11), 0, 0, 0):gap(theme:px(2))
		s.title = theme:s():w(width):text(theme:type("base")):weight("semibold"):fg(theme:color("text")):ellipsis()
		s.artist = theme:s():w(width):text(theme:type("sm")):weight("regular"):fg(theme:color("muted")):ellipsis()
		s.iconSize = theme:px(18)
		s.radius = theme:radius("md")
	end

	-- The cover's props are kept with the card and only the size is written again: a cover is
	-- asked for on every card of every frame, and a props table it is only read from is not one
	-- the frame has to make.
	local coverProps = kept.cover --[[@as table<string, any>]]
	coverProps.album, coverProps.size, coverProps.radius = album, width, s.radius

	-- The children are handed over one at a time rather than as a table: this runs for every card of
	-- every frame, and a table a card is only a list of is a table that frame no longer needs.
	return div()
		:style(s.card):hover(s.cardHover):onClick(actions.open)
		:onContextMenu(actions.menu)
		:children(
			div()
				:style(s.art)
				:children(
					cover.view(app, coverProps --[[@as beat.components.CoverProps]]),
					div()
						:style(s.play):onClick(onPlay)
						:children(
							ui.icon(ctx, { name = playing ? "pause" : "play", size = s.iconSize, colour = theme.accentInk })
						)
				),
			div()
				:style(s.block)
				:children(text(album.title):style(s.title), text(album.artist):style(s.artist))
		)
end

return albumCard
