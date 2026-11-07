-- The seek bar of the playing track: elapsed time, the slider that seeks, and the total.
local wonderland = require("wonderland")
local format = require("beat.app.components.helpers.format")
local slider = require("beat.app.components.slider")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local progress = {}

---@class beat.components.ProgressProps
---@field track beat.Track
---@field player beat.Player # The player whose position the bar follows
---@field width number # Room for both clocks and the slider together

---@param app beat.App
---@param props beat.components.ProgressProps
---@return wonderland.Element
function progress.view(app, props)
	local theme = app.services.appearance.theme
	local track, player, width = props.track, props.player, props.width
	local duration = track.duration > 0 and track.duration or player:duration()
	local position = player:position()
	local clockWidth = theme:px(34)
	local gap = theme:px(8)
	local trackWidth = width - clockWidth * 2 - gap * 2

	local function clock(value)
		return div():style(sty():w(clockWidth):h(theme:px(18)):row():align("center"):justify("center"))
		:children(text(format.clock(value)):style(theme:s():text(theme:type("xs"))
		:fg(theme:color("faint"))))
	end

	return div():style(sty():w(width):h(theme:px(18)):row():align("center"):gap(gap)):children({
	clock(position),
	slider.view(app, {
	width = trackWidth,
	value = position,
	min = 0,
	max = duration > 0 and duration or 1,
	onchange = function(value) return { type = "seek", seconds = value} end,
	trackColour = theme:color("text", 0.12),
	fillColour = theme:color("text"),
	thumbColour = theme:color("text"),
	}),
	clock(duration),
	})
end

return progress
