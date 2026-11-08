-- A track in a table: its number or the playing mark, the title and artist, its album where there
-- is room for one, and its time. The album page's table sets titles only, because its header
-- names the artist.
local wonderland = require("wonderland")
local format = require("beat.app.components.helpers.format")
local playingBars = require("beat.app.components.playing_bars")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local trackRow = {}

---@class beat.components.TrackRowProps
---@field track beat.Track
---@field index number # The number the row shows when it is not playing
---@field current boolean # Whether this track is the one playing
---@field playing boolean # Whether playback is running
---@field onClick any # The message a click sends, unless the row is the current track
---@field width number? # Default theme:px(760)
---@field showAlbum boolean? # Default true, until the row gets too narrow for the column
---@field titleOnly boolean? # Hide the artist's line; the caller's header names it

---@param app beat.App
---@param props beat.components.TrackRowProps
---@return wonderland.Element
function trackRow.view(app, props)
	local theme = app.services.appearance.theme
	local track, index, current = props.track, props.index, props.current
	local onClick = props.onClick
	if current then onClick = { type = "togglePlay"} end
	local titleColour = current ? (theme:color("accent")) : (theme:color("text"))
	local muted = theme:color("muted")
	local rowBg = current ? (theme:color("accent", 0.07)) : (theme:color("surface", 0))
	local hoverBg = theme:color("hover")

	local marker
	if current then
		marker = playingBars.view(app, { playing = props.playing })
	else
		marker = text(tostring(index)):style(theme:s():text(theme:type("sm")):fg(theme:color("faint")))
	end

	local width = props.width or theme:px(760)
	-- The album column is the first thing a phone cannot afford. Keeping the title and time
	-- legible is more useful than three columns squeezed into a narrow list.
	local albumColumn = props.showAlbum ~= false and width >= theme:px(520)
	local infoWidth = math.max(theme:px(100),
	width - (albumColumn and theme:px(324) or theme:px(122)))
	local info = {
		text(track.title):style(theme:s():w(infoWidth):text(theme:type("base")):weight("medium")
		:fg(titleColour):ellipsis()),
	}
	if not props.titleOnly then
		info[#info + 1] = text(track.artist):style(theme:s():w(infoWidth):text(theme:type("sm"))
		:fg(muted):ellipsis())
	end
	local children = {
		div():style(sty():w(24):align("center")):children(marker),
		div():style(sty():w(infoWidth):h(48):column():justify("center"):gap(1)):children(info),
	}

	if albumColumn then
		children[#children + 1] = div():style(sty():w(190):h(48):column():justify("center")):children(
		text(track.album):style(theme:s():w(190):text(theme:type("sm")):fg(muted):ellipsis())
		)
	end

	children[#children + 1] = div():style(sty():w(54):h(48):column():align("start"):justify("center")):children(
	text(format.clock(track.duration)):style(theme:s():text(theme:type("sm")):fg(muted))
	)

	return div()
	:style(sty():row():w(width):h(48):pad(0, theme:px(10), 0, theme:px(10)):gap(theme:px(12))
	:align("center"):radius(theme:radius("sm")):bg(rowBg))
	:hover(sty():row():w(width):h(48):pad(0, theme:px(10), 0, theme:px(10)):gap(theme:px(12))
	:align("center"):radius(theme:radius("sm")):bg(hoverBg))
	:onClick(onClick)
	:onContextMenu(|_, _, _, _, _, windowX, windowY| -> { type = "open", overlay = "menu", menu = "track", id = track.id, x = windowX, y = windowY})
	:children(children)
end

return trackRow
