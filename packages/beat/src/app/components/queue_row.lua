-- A row of the queue panel: its title and artist, its length, and -- where a pointer can hover --
-- the button that takes it out of the queue. The row also draws the two states a gesture puts it
-- in: sliding sideways to be removed, and lifted out of the stack while the rows around it take
-- the places a drop would give them.
--
-- Everything here is a function of the theme, the size the list gives a row, and the gesture the
-- overlay keeps. The boxes and text styles are made once for each of those and handed to every
-- frame, and a dragged or sliding row reuses one builder and only moves it, so scrolling the queue
-- or holding a row does not make a table a frame.
local wonderland = require("wonderland")
local format = require("beat.app.components.helpers.format")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local queueRow = {}

-- The length a track shows, kept per track: the row is built again on every frame of a gesture or
-- a scroll, and the clock does not change.
---@type table<beat.Track, string>
local clocks = setmetatable({}, { __mode = "k" })

---@param track beat.Track
---@return string
local function clockFor(track)
	local clock = clocks[track]
	if clock == nil then
		clock = format.clock(track.duration)
		clocks[track] = clock
	end
	return clock
end

---@class beat.QueueDrag
---@field index number # The row's 1-based place in the displayed list when it was pressed
---@field contentY number # Where the press was in the list's content, in pixels
---@field dy number # How far the pointer has moved from the press, in the content's pixels
---@field lastDy number # The offset the last frame was asked to repaint with
---@field to number # The place the row would land if it were let go now

---@class beat.QueueSwipe
---@field index number # The row being slid out
---@field x number # Where the press that began it was, across the list
---@field dx number # How far it has slid, in pixels

---@class beat.components.QueueRowStyles
---@field base wonderland.StyleBuilder
---@field hover wonderland.StyleBuilder
---@field lifted wonderland.StyleBuilder
---@field gap wonderland.StyleBuilder
---@field swipe wonderland.StyleBuilder
---@field info wonderland.StyleBuilder
---@field title wonderland.StyleBuilder
---@field artist wonderland.StyleBuilder
---@field clockBox wonderland.StyleBuilder
---@field clock wonderland.StyleBuilder
---@field removeBox wonderland.StyleBuilder
---@field removeSpacer wonderland.StyleBuilder
---@field removeText wonderland.StyleBuilder
---@field removeTextHover wonderland.StyleBuilder

---@param theme beat.Theme
---@param width number
---@param height number
---@param mobile boolean
---@return beat.components.QueueRowStyles
local function build(theme, width, height, mobile)
	local pad = theme:px(8)
	local gap = theme:px(8)
	local clockWidth = theme:px(44)
	local removeWidth = mobile and 0 or theme:px(32)
	local infoWidth = width - pad * 2 - clockWidth - removeWidth - (mobile and gap or gap * 2)

	---@return wonderland.StyleBuilder
	local function rowStyle()
		return sty()
			:row():w(width):h(height):pad(0, pad, 0, pad):gap(gap):align("center"):radius(theme:radius("sm"))
	end

	return {
		base = rowStyle(),
		hover = rowStyle():bg(theme:color("hover")),
		-- The row a finger or a pointer has lifted: it is drawn over its neighbours and follows the
		-- hand, and its place in the content is written into this builder every frame. A row placed
		-- by hand is out of the stack, which is why the stack keeps a gap where it would land.
		lifted = rowStyle():bg(theme:color("elevated")):shadow(0, theme:px(10), theme:px(24), "#00000088"):z(200),
		-- What a row would land on: the box the stack leaves for it, drawn faintly so the place is
		-- seen even when a finger covers the lifted row itself.
		gap = rowStyle():bg(theme:color("hover", 0.5)),
		-- A row sliding out keeps its place in the stack and only moves across it.
		swipe = rowStyle():bg(theme:color("danger", 0.2)),
		info = sty():column():w(infoWidth):h(height):justify("center"),
		title = theme:s():w(infoWidth):text(theme:type("sm")):weight("semibold"):fg(theme:color("text")):ellipsis(),
		artist = theme:s():w(infoWidth):text(theme:type("xs")):fg(theme:color("muted")):ellipsis(),
		clockBox = sty():row():w(clockWidth):h(height):align("center"):justify("end"),
		clock = theme:s():text(theme:type("xs")):fg(theme:color("faint")),
		-- A press target as tall as the row and as wide as the icon needs, so the remove button is
		-- easy to hit. It is there without being drawn, which keeps a row's text from reflowing
		-- when the pointer arrives.
		removeBox = sty():size(removeWidth, height):align("center"):justify("center"),
		removeSpacer = sty():size(removeWidth, height),
		removeText = theme:s():text(theme:type("lg")):weight("medium"):fg(theme:color("muted")),
		removeTextHover = theme:s():text(theme:type("lg")):weight("medium"):fg(theme:color("danger"))
	}
end

--- The boxes for one list width, row height and kind of screen, kept with the theme: every row
--- of every frame asks for the same record.
---@param theme beat.Theme
---@param width number
---@param height number
---@param mobile boolean
---@return beat.components.QueueRowStyles
local function stylesFor(theme, width, height, mobile)
	local cache = theme:cache()
	---@type table<number, table<number, table<boolean, beat.components.QueueRowStyles>>>
	local widths = cache.queueRows
	if widths == nil then
		widths = {}
		cache.queueRows = widths
	end
	local heights = widths[width]
	if heights == nil then
		heights = {}
		widths[width] = heights
	end
	local modes = heights[height]
	if modes == nil then
		modes = {}
		heights[height] = modes
	end
	local styles = modes[mobile]
	if styles == nil then
		styles = build(theme, width, height, mobile)
		modes[mobile] = styles
	end
	return styles
end

---@class beat.components.QueueRowProps
---@field theme beat.Theme
---@field track beat.Track
---@field index number # Its 1-based place in the displayed list
---@field width number
---@field height number
---@field mobile boolean
---@field hover number? # The place of the row the pointer is over
---@field drag beat.QueueDrag?
---@field swipe beat.QueueSwipe?
---@field removeMessage table? # What the remove button sends for this row

--- One row, in whatever state the overlay is in. The table is the overlay's and its fields are
--- written again for each row, because the element is what outlives the call and the props do not.
---@param props beat.components.QueueRowProps
---@return wonderland.Element
function queueRow.view(props)
	local theme = props.theme
	local styles = stylesFor(theme, props.width, props.height, props.mobile)
	local style, hover = styles.base, styles.hover
	local drag = props.drag
	local swipe = props.swipe
	local index = props.index

	if drag ~= nil and index == drag.index then
		-- A lifted row is placed by hand: relative to the list's content, not to a slot in the
		-- stack, so it can be anywhere the pointer is while the stack shows where it would land.
		styles.lifted:offset(0, (drag.index - 1) * props.height + drag.dy)
		style = styles.lifted
		hover = nil
	elseif swipe ~= nil and index == swipe.index then
		-- Across the stack rather than out of it: its slot stays where it is.
		styles.swipe:margin(0, 0, 0, swipe.dx)
		style = styles.swipe
		hover = nil
	end

	local track = props.track
	local children = {
		div():style(styles.info):children(
			{
				text(track.title):style(styles.title),
				text(track.artist):style(styles.artist)
			}
		),
		div():style(styles.clockBox):children(
			text(clockFor(track)):style(styles.clock)
		)
	}

	if not props.mobile then
		if props.hover == index and drag == nil and swipe == nil then
			children[#children + 1] = div():style(styles.removeBox):onClick(props.removeMessage):children(
				text("×"):style(styles.removeText):hover(styles.removeTextHover)
			)
		else
			children[#children + 1] = div():style(styles.removeSpacer)
		end
	end

	local row = div():style(style)
	if hover ~= nil then row:hover(hover) end
	return row:children(children)
end

--- The empty box a stack leaves where a lifted row would land.
---@param props beat.components.QueueRowProps
---@return wonderland.Element
function queueRow.gap(props)
	local styles = stylesFor(props.theme, props.width, props.height, props.mobile)
	return div():style(styles.gap)
end

---@class beat.components.QueueHeadingStyles
---@field row wonderland.StyleBuilder
---@field emptyRow wonderland.StyleBuilder
---@field title wonderland.StyleBuilder
---@field count wonderland.StyleBuilder
---@field empty wonderland.StyleBuilder

--- The three lines around the rows -- the panel's heading, its count, and what it says when it is
--- empty -- kept with the theme rather than made again with every frame of a scroll.
---@param theme beat.Theme
---@return beat.components.QueueHeadingStyles
function queueRow.heading(theme)
	local cache = theme:cache()
	local heading = cache.queueHeading --[[@as beat.components.QueueHeadingStyles?]]
	if heading == nil then
		heading = {
			row = sty():row():wrel(1.0):h(theme:px(24)):align("center"):justify("space-between"),
			emptyRow = sty():row():wrel(1.0):h(theme:px(48)):align("center"),
			title = theme:s():text(theme:type("xs")):weight("bold"):fg(theme:color("muted")),
			count = theme:s():text(theme:type("xs")):fg(theme:color("faint")),
			empty = theme:s():text(theme:type("sm")):fg(theme:color("muted"))
		}
		cache.queueHeading = heading
	end
	return heading
end

return queueRow
