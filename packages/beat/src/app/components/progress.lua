-- The seek bar of the playing track: elapsed time, the slider that seeks, and the total.
local wonderland = require("wonderland")
local format = require("beat.app.components.helpers.format")
local slider = require("beat.app.components.slider")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local progress = {}

--- The clock at one end of the bar.
---@param styles beat.components.ProgressStyles # What the theme kept for this width
---@param value number
local function clock(styles, value)
	return div():style(styles.clock):children(text(format.clock(value)):style(styles.text))
end

--- Where the player is when the frame is drawn: what the slider follows, made once rather than
--- for every frame of the bar.
---@param player beat.Player
local function followPlayer(player)
	return || -> player:position()
end

--- What dragging the bar asks for: a place in the track.
---@param seconds number
---@return table
local function seekTo(seconds)
	return { type = "seek", seconds = seconds }
end

--- How tall the bar is. The phone's clocks are set in body type so they read at arm's length, and
--- the row grows with them; the desktop keeps a caption line.
---@param theme beat.Theme
---@param mobile boolean?
---@return number
function progress.height(theme, mobile)
	return mobile and theme:px(24) or theme:px(18)
end

--- What the theme keeps for one width of the bar: the two clocks, the row they sit in, and the way
--- the slider asks the player where it is.
---@class beat.components.ProgressStyles
---@field width number
---@field mobile boolean
---@field player beat.Player
---@field clock wonderland.StyleBuilder
---@field text wonderland.StyleBuilder
---@field row wonderland.StyleBuilder
---@field liveValue fun(): number

---@class beat.components.ProgressProps
---@field track beat.Track
---@field player beat.Player # The player whose position the bar follows
---@field width number # Room for both clocks and the slider together
---@field mobile boolean? # Set in body type for a phone, where the clocks are read from a distance

---@param app beat.App
---@param props beat.components.ProgressProps
---@return wonderland.Element
function progress.view(app, props)
	local theme = app.services.appearance.theme
	local track, player, width = props.track, props.player, props.width
	local mobile = props.mobile == true
	local duration = track.duration > 0 and track.duration or player:duration()
	local position = player:position()
	local height = progress.height(theme, mobile)
	-- Room for `12:34` at body size, and the same on the desktop for its caption.
	local clockWidth = mobile and theme:px(48) or theme:px(34)
	local gap = theme:px(8)
	local trackWidth = width - clockWidth * 2 - gap * 2

	-- The styles are the same for every frame of every track: they are kept on the theme rather
	-- than built again, for the width they were built for -- the one thing they depend on besides
	-- the theme. A second progress bar in the same frame (the now-playing screen's) has its own
	-- width, so it builds its own, which is what it did every frame before.
	---@type table<string, any>
	local cache = theme:cache()
	local styles = cache.progress --[[@as beat.components.ProgressStyles?]]
	if styles == nil or styles.width ~= width or styles.mobile ~= mobile or styles.player ~= player then
		styles = {
			width = width,
			mobile = mobile,
			player = player,
			clock = sty():w(clockWidth):h(height):row():align("center"):justify("center"),
			text = theme:s():text(theme:type(mobile and "md" or "xs")):fg(theme:color("faint")),
			row = sty():w(width):h(height):row():align("center"):gap(gap),
			liveValue = followPlayer(player)
		}
		cache.progress = styles
	end

	return div():style(styles.row):children({
		clock(styles, position),
		slider.view(app, {
			width = trackWidth,
			value = position,
			min = 0,
			max = duration > 0 and duration or 1,
			onchange = seekTo,
			-- The playhead moves every frame of a track while the clock beside it moves
			-- once a second, so the bar follows the player when the frame is drawn: a
			-- repaint shows where it is without laying the row out again.
			liveValue = styles.liveValue,
			-- The bar and the now-playing screen have a slider each for the same player; the
			-- player is what says a slider is this one rather than another of the same size.
			instance = player,
			trackColour = theme:color("text", 0.12),
			fillColour = theme:color("text"),
			thumbColour = theme:color("text")
		}),
		clock(styles, duration)
	})
end

return progress
