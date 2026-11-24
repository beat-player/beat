-- A track in a table: its number, its album's cover or the playing mark, the title and artist, its
-- album where there is room for one, its rating where the table asks for one, and its time. The
-- album page's table sets titles only, because its header names the artist.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local format = require("beat.app.components.helpers.format")
local playingBars = require("beat.app.components.playing_bars")
local styles = require("beat.app.components.helpers.styles")
local cover = require("beat.app.components.cover")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local trackRow = {}

-- The number a row shows, kept per index: a row is built on every frame of a scroll, and the
-- number it shows is the same one each time.
---@type table<number, string>
local indexTexts = {}

---@param index number
---@return string
local function indexText(index)
	local known = indexTexts[index]
	if known == nil then
		known = tostring(index)
		indexTexts[index] = known
	end
	return known
end

--- Three dots, drawn rather than taken from the icon face: the face has no ellipsis, and this is
--- the same mark the now-playing view's larger menu uses. A canvas draws it at every size.
---@class beat.components.TrackRowDots
---@field style wonderland.StyleBuilder
---@field draw fun(canvas: wonderland.Canvas)

--- The three dots at one size and colour, made where the row's record is made rather than in the
--- view: a function declared in the view is one the trace compiler closes an upvalue on for every
--- row of every frame.
---@param size number
---@param colour string
---@return fun(canvas: wonderland.Canvas)
local function dotsDraw(size, colour)
	local radius = math.max(1.2, math.floor(size * 0.064))
	return function(canvas)
		local y = math.floor(canvas.height / 2 - radius)
		for at = 0, 2 do
			local x = math.floor(canvas.width / 2 + (at - 1) * size * 0.21 - radius)
			canvas:rect(x, y, radius * 2, radius * 2, colour, radius)
		end
	end
end

---@param theme beat.Theme
---@param size number
---@param colour string
local function dots(theme, size, colour)
	---@type table<string, any>
	local cache = theme:cache()
	local kept = cache.trackRowDots --[[@as table<number, beat.components.TrackRowDots>?]]
	if kept == nil then
		kept = {}
		cache.trackRowDots = kept
	end
	local mark = kept[size]
	if mark == nil then
		mark = { style = sty():size(size, size), draw = dotsDraw(size, colour) }
		kept[size] = mark
	end
	return div():style(mark.style):canvas(mark.draw)
end

-- What a click on the current track's row sends.
local TOGGLE_PLAY = { type = "togglePlay" }

-- A row's stars' handler, one per track rather than one per row per frame.
---@type table<beat.Track, fun(stars: number): table>
local rates = setmetatable({}, { __mode = "k" })
-- The menu a row opens, one per track. The message names no place: a right-click opens the menu
-- where the pointer is, which is where the click landed, and a tap on the dots opens it beside
-- them (see `beat.MenuOverlay`). A message rather than a function keeps the row's view from
-- making a closure on every frame.
---@type table<beat.Track, table>
local mores = setmetatable({}, { __mode = "k" })

---@param track beat.Track
---@return table
local function moreFor(track)
	local more = mores[track]
	if more == nil then
		more = { type = "open", overlay = "menu", menu = "track", id = track.id }
		mores[track] = more
	end
	return more
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
---@field coverSize number
---@field coverShade wonderland.StyleBuilder
---@field coverBox wonderland.StyleBuilder
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
---@field mobile boolean? # The phone's row: two lines, a taller target and its own menu button
---@field ui beat.ui.Context? # Needed with `rating` and on a phone's row
---@field showCover boolean? # The album's cover leads the row instead of its number: a list of tracks from many albums, where a number says nothing

--- The stars column: as wide as five stars at the table's size, and kept only while the row is
--- wide enough for the title to stay readable beside it. A phone's row also spends room on its
--- menu button, so it asks for more before it offers the column.
---@param app beat.App
---@param width number # The row's width
---@param mobile boolean?
---@return number? # The column's width, or nothing when the row cannot afford it
function trackRow.ratingWidth(app, width, mobile)
	local theme = app.services.appearance.theme
	if width < theme:px(mobile and 416 or 360) then return nil end
	return theme:px(14) * 5 + theme:px(2) * 4
end

--- The row's own box: one width and height, and the padding and gap every column sits in. It is
--- made by a function of its own rather than by one declared inside the view, so the frame that
--- draws a list makes no closure and its trace can be compiled.
---@param theme beat.Theme
---@param width number
---@param rowHeight number
---@return wonderland.StyleBuilder
local function rowStyle(theme, width, rowHeight)
	return sty():row():w(width):h(rowHeight):pad(0, theme:px(10), 0, theme:px(10)):gap(theme:px(12)):align(
		"center"
	):radius(theme:radius("sm"))
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
	local mobile = props.mobile == true
	-- A row asks the ratings plugin before spending a column on stars; the caller may still pass
	-- a value, because the data is there whether the feature is on or not.
	local ratings = app.registry:hasPlugin("ratings")
	-- The album column is the first thing a phone cannot afford. Keeping the title and time
	-- legible is more useful than three columns squeezed into a narrow list.
	local albumColumn = props.showAlbum ~= false and width >= theme:px(520)
	local ratingWidth = ratings and props.rating ~= nil and props.ui ~= nil and trackRow.ratingWidth(app, width, mobile) or nil

	-- One set per width, playing state, set of columns and phone-or-not: everything below is a
	-- function of those.
	local byWidth = styles.of(
		theme,
		(current and "trackRowCurrent" or "trackRow") .. (mobile and "Phone" or ""),
		width
	)
	local showCover = props.showCover == true
	local shape = (albumColumn and 1 or 0) + (ratingWidth ~= nil and 2 or 0) + (showCover and 4 or 0)
	local s = byWidth[shape] --[[@as beat.components.TrackRowStyles?]]
	if s == nil then
		local titleColour = current ? (theme:color("accent")) : (theme:color("text"))
		local muted = theme:color("muted")
		-- A phone's row spends its last column on the menu's button, and gives the two lines the
		-- height a finger needs rather than the desk row's one line of forty-eight.
		local moreWidth = mobile and theme:px(44) or 0
		-- Every width and height here is a length in the theme's units: a row is the same shape
		-- at the listener's scale, and its columns add up to the width it is given.
		local rowHeight = mobile and theme:px(64) or theme:px(48)
		local fixedWidth = albumColumn and theme:px(324) or theme:px(122)
		if mobile then fixedWidth += moreWidth + theme:px(12) end
		-- A cover is wider than the number it replaces, and the title gives up the difference.
		local coverSize = theme:px(mobile and 44 or 36)
		if showCover then fixedWidth += coverSize - theme:px(24) end
		local infoWidth = math.max(
			theme:px(100),
			width - fixedWidth - (ratingWidth ~= nil and ratingWidth + theme:px(12) or 0)
		)
		s = {
			index = theme:s():text(theme:type("sm")):fg(theme:color("faint")),
			markerBox = sty():w(showCover and coverSize or theme:px(24)):align("center"),
			coverSize = coverSize,
			coverBox = sty():size(coverSize, coverSize),
			coverShade = sty()
				:size(coverSize, coverSize):offset(0, 0):radius(theme:radius("sm")):bg("#00000099")
				:align("center"):justify("center"),
			info = sty():w(infoWidth):h(rowHeight):column():justify("center"):gap(mobile and theme:px(2) or theme:px(1)),
			title = theme:s():w(infoWidth):text(theme:type("base")):weight(mobile and "semibold" or "medium")
				:fg(titleColour):ellipsis(),
			artist = theme:s():w(infoWidth):text(theme:type("sm")):fg(muted):ellipsis(),
			albumBox = sty():w(theme:px(190)):h(rowHeight):column():justify("center"),
			album = theme:s():w(theme:px(190)):text(theme:type("sm")):fg(muted):ellipsis(),
			timeBox = sty():w(theme:px(54)):h(rowHeight):column():align("start"):justify("center"),
			time = theme:s():text(theme:type("sm")):fg(muted),
			row = rowStyle(theme, width, rowHeight):bg(current ? (theme:color("accent", 0.07)) : (theme:color("surface", 0))),
			rowHover = rowStyle(theme, width, rowHeight):bg(theme:color("hover")),
			starSize = theme:px(14),
			starGap = theme:px(2)
		}
		byWidth[shape] = s
	end

	local marker
	local library = app.services.library.current
	local album = nil
	if showCover and library ~= nil then album = library:album(track.albumId) end
	if album ~= nil then
		marker = div():style(s.coverBox):children({ cover.view(app, { album = album, size = s.coverSize, radius = theme:radius("sm") }) })
		-- The playing track keeps its cover, dimmed under the moving bars.
		if current then
			marker:children({ div():style(s.coverShade):children({ playingBars.view(app, { playing = props.playing }) }) })
		end
	elseif current then
		marker = playingBars.view(app, { playing = props.playing })
	else
		marker = text(indexText(index)):style(s.index)
	end

	local info = { text(track.title):style(s.title) }
	-- A phone's row is two lines whoever's header names the artist: there is room under the
	-- title, and the header's word alone is not the artist.
	if mobile or not props.titleOnly then
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

	if mobile then
		-- A round icon button, the same hit area every other icon has; the dots are its content.
		local size = theme:px(44)
		children[#children + 1] = ui.iconButton(
			assert(props.ui),
			{ size = size, onClick = moreFor(track), content = dots(theme, size, theme:color("muted")) }
		)
	end

	return div():style(s.row):hover(s.rowHover):onClick(onClick):onContextMenu(moreFor(track)):children(children)
end

return trackRow
