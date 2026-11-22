-- A track in a table: its number or the playing mark, the title and artist, its album where there
-- is room for one, its rating where the table asks for one, and its time. The album page's table
-- sets titles only, because its header names the artist.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local format = require("beat.app.components.helpers.format")
local playingBars = require("beat.app.components.playing_bars")
local styles = require("beat.app.components.helpers.styles")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local trackRow = {}

-- What a click on the current track's row sends.
local TOGGLE_PLAY = { type = "togglePlay" }

-- A row's right-click menu and its stars' handler, one per track rather than one per row per frame.
---@type table<beat.Track, fun(...): table>
local menus = setmetatable({}, { __mode = "k" })
---@type table<beat.Track, fun(stars: number): table>
local rates = setmetatable({}, { __mode = "k" })

---@param track beat.Track
local function menuFor(track)
	local menu = menus[track]
	if menu == nil then
		local id = track.id
		menu = |_, _, _, _, _, windowX, windowY| -> {
			type = "open",
			overlay = "menu",
			menu = "track",
			id = id,
			x = windowX,
			y = windowY
		}
		menus[track] = menu
	end
	return menu
end

---@param track beat.Track
local function rateFor(track)
	local rate = rates[track]
	if rate == nil then
		local id = track.id
		rate = |stars| -> { type = "rateTrack", id = id, stars = stars }
		rates[track] = rate
	end
	return rate
end

---@class beat.components.TrackRowStyles
---@field index wonderland.StyleBuilder
---@field markerBox wonderland.StyleBuilder
---@field info wonderland.StyleBuilder
---@field title wonderland.StyleBuilder
---@field artist wonderland.StyleBuilder
---@field albumBox wonderland.StyleBuilder
---@field album wonderland.StyleBuilder
---@field timeBox wonderland.StyleBuilder
---@field time wonderland.StyleBuilder
---@field row wonderland.StyleBuilder
---@field rowHover wonderland.StyleBuilder
---@field starSize number
---@field starGap number

---@class beat.components.TrackRowProps
---@field track beat.Track
---@field index number # The number the row shows when it is not playing
---@field current boolean # Whether this track is the one playing
---@field playing boolean # Whether playback is running
---@field onClick any # The message a click sends, unless the row is the current track
---@field width number? # Default theme:px(760)
---@field showAlbum boolean? # Default true, until the row gets too narrow for the column
---@field titleOnly boolean? # Hide the artist's line; the caller's header names it
---@field rating number? # The track's stars, drawn and set in a column of their own; none hides the column
---@field ui beat.ui.Context? # Needed with `rating`

--- The stars column: as wide as five stars at the table's size, and kept only while the row is
--- wide enough for the title to stay readable beside it.
---@param app beat.App
---@param width number # The row's width
---@return number? # The column's width, or nothing when the row cannot afford it
function trackRow.ratingWidth(app, width)
	local theme = app.services.appearance.theme
	if width < theme:px(360) then return nil end
	return theme:px(14) * 5 + theme:px(2) * 4
end

---@param app beat.App
---@param props beat.components.TrackRowProps
---@return wonderland.Element
function trackRow.view(app, props)
	local theme = app.services.appearance.theme
	local track, index, current = props.track, props.index, props.current
	local onClick = props.onClick
	if current then onClick = TOGGLE_PLAY end

	local width = props.width or theme:px(760)
	-- The album column is the first thing a phone cannot afford. Keeping the title and time
	-- legible is more useful than three columns squeezed into a narrow list.
	local albumColumn = props.showAlbum ~= false and width >= theme:px(520)
	local ratingWidth = props.rating ~= nil and props.ui ~= nil and trackRow.ratingWidth(app, width) or nil

	-- One set per width, playing state and set of columns: everything below is a function of those.
	local byWidth = styles.of(theme, current and "trackRowCurrent" or "trackRow", width)
	local shape = (albumColumn and 1 or 0) + (ratingWidth ~= nil and 2 or 0)
	local s = byWidth[shape] --[[@as beat.components.TrackRowStyles?]]
	if s == nil then
		local titleColour = current ? (theme:color("accent")) : (theme:color("text"))
		local muted = theme:color("muted")
		local infoWidth = math.max(
			theme:px(100),
			width - (albumColumn and theme:px(324) or theme:px(122)) - (ratingWidth ~= nil and ratingWidth + theme:px(12) or 0)
		)
		local function row()
			return sty():row():w(width):h(48):pad(0, theme:px(10), 0, theme:px(10)):gap(theme:px(12)):align("center")
				:radius(theme:radius("sm"))
		end
		s = {
			index = theme:s():text(theme:type("sm")):fg(theme:color("faint")),
			markerBox = sty():w(24):align("center"),
			info = sty():w(infoWidth):h(48):column():justify("center"):gap(1),
			title = theme:s():w(infoWidth):text(theme:type("base")):weight("medium"):fg(titleColour):ellipsis(),
			artist = theme:s():w(infoWidth):text(theme:type("sm")):fg(muted):ellipsis(),
			albumBox = sty():w(190):h(48):column():justify("center"),
			album = theme:s():w(190):text(theme:type("sm")):fg(muted):ellipsis(),
			timeBox = sty():w(54):h(48):column():align("start"):justify("center"),
			time = theme:s():text(theme:type("sm")):fg(muted),
			row = row():bg(current ? (theme:color("accent", 0.07)) : (theme:color("surface", 0))),
			rowHover = row():bg(theme:color("hover")),
			starSize = theme:px(14),
			starGap = theme:px(2)
		}
		byWidth[shape] = s
	end

	local marker
	if current then
		marker = playingBars.view(app, { playing = props.playing })
	else
		marker = text(tostring(index)):style(s.index)
	end

	local info = { text(track.title):style(s.title) }
	if not props.titleOnly then
		info[#info + 1] = text(track.artist):style(s.artist)
	end
	local children = {
		div():style(s.markerBox):children(marker),
		div():style(s.info):children(info)
	}

	if albumColumn then
		children[#children + 1] = div():style(s.albumBox):children(text(track.album):style(s.album))
	end

	if ratingWidth ~= nil then
		-- A star is its own target: setting a rating does not also play the track.
		children[#children + 1] = ui.rating(
			assert(props.ui),
			{ value = props.rating or 0, onRate = rateFor(track), size = s.starSize, gap = s.starGap }
		)
	end

	children[#children + 1] = div():style(s.timeBox):children(text(format.clock(track.duration)):style(s.time))

	return div():style(s.row):hover(s.rowHover):onClick(onClick):onContextMenu(menuFor(track)):children(children)
end

return trackRow
