-- An album as the shelf shows it: its cover with a play control, and the title block beneath.
local wonderland = require("wonderland")
local icon = require("beat.app.components.icon")
local cover = require("beat.app.components.cover")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local albumCard = {}

---@class beat.components.AlbumCardProps
---@field album beat.Album
---@field width number # The card's width; the cover is square
---@field onOpen any # The message a click on the card sends
---@field onPlay any # The message the play control sends, unless this album is already playing
---
---@class beat.components.AlbumCardHeightProps
---@field width number # The card's width

--- The card's cover plus the title block beneath it. The block's height comes from the type it
--- sets, rather than a fixed guess: a type scale change must not cut an artist line in half.
---@param app beat.App
---@param props beat.components.AlbumCardHeightProps
---@return number
function albumCard.height(app, props)
	local theme = app.services.appearance.theme
	local width = props.width
	return width + theme:px(11) + theme:type("base") + theme:px(2) + theme:type("sm")
end

---@param app beat.App
---@param props beat.components.AlbumCardProps
---@return wonderland.Element
function albumCard.view(app, props)
	local theme = app.services.appearance.theme
	local album, width, onPlay = props.album, props.width, props.onPlay
	local current = app.services.playback:current()
	local thisAlbum = current ~= nil and current.albumId == album.id
	local playing = thisAlbum and app.services.playback.player:isPlaying()
	if thisAlbum then onPlay = { type = "togglePlay"} end

	local titleStyle = theme:s():w(width):text(theme:type("base")):weight("semibold"):fg(theme:color("text")):ellipsis()
	local artistStyle = theme:s():w(width):text(theme:type("sm")):weight("regular"):fg(theme:color("muted")):ellipsis()

	local height = albumCard.height(app, { width = width })
	return div()
	:style(sty():w(width):h(height):column())
	:hover(sty():w(width):h(height):column():bright(1.08))
	:onClick(props.onOpen)
	:onContextMenu(function(_, _, _, _, _, windowX, windowY)
		return { type = "open", overlay = "menu", menu = "album", id = album.id, x = windowX, y = windowY}
	end)
	:children({
		div():style(sty():size(width, width)):children({
			cover.view(app, { album = album, size = width, radius = theme:radius("md"), sheen = true }),
			div()
			:style(sty():size(theme:px(36), theme:px(36)):radius(theme:radius("full"))
			:offset(width - theme:px(44), width - theme:px(44))
			:bg(theme:color("accent")):align("center"):justify("center"))
			:onClick(onPlay)
			:children(icon.view(app, { name = playing and "pause" or "play", size = theme:px(18), colour = theme.accentInk })),
		}),
		div():style(sty():column():pad(theme:px(11), 0, 0, 0):gap(theme:px(2))):children({
			text(album.title):style(titleStyle),
			text(album.artist):style(artistStyle),
		}),
	})
end

return albumCard
