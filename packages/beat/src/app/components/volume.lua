-- The volume control: a mute toggle and a slider over the settings' volume.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local slider = require("beat.app.components.slider")

local div, sty = wonderland.div, wonderland.sty

local volume = {}

--- What moving the slider asks for: the volume, as the settings keep it.
---@param value number
---@return table
local function volumeChanged(value)
	return { type = "volume", value = value }
end

--- What the theme keeps for one width of the control: the row it sits in and the slot the icon
--- is centred in.
---@class beat.components.VolumeStyles
---@field width number
---@field trackWidth number?
---@field row wonderland.StyleBuilder
---@field slot wonderland.StyleBuilder

---@class beat.components.VolumeProps
---@field width number # The whole control, icon and slider together
---@field trackWidth number? # The slider track, when it should line up with another slider's track
---@field ui beat.ui.Context

---@param app beat.App
---@param props beat.components.VolumeProps
---@return wonderland.Element
function volume.view(app, props)
	local theme = app.services.appearance.theme
	local ctx = props.ui
	local width = props.width
	local trackWidth = props.trackWidth
	local value = app.services.settings.values.isMuted ? 0 : app.services.settings.values.volume
	local iconSlot = trackWidth ~= nil ? (theme:px(34)) : (theme:px(22))
	local sliderWidth = trackWidth or (width - theme:px(30))

	-- Kept on the theme, for the width they were built for: what they depend on besides it is the
	-- track width, which goes with the width.
	---@type table<string, any>
	local cache = theme:cache()
	local styles = cache.volume --[[@as beat.components.VolumeStyles?]]
	if styles == nil or styles.width ~= width or styles.trackWidth ~= trackWidth then
		styles = {
			width = width,
			trackWidth = trackWidth,
			row = sty():w(width):h(theme:px(22)):row():align("center"):gap(theme:px(8)),
			slot = sty():w(iconSlot):h(theme:px(22)):row():align("center"):justify("center")
		}
		cache.volume = styles
	end

	return div():style(styles.row):children({
		div():style(styles.slot):children(ui.iconButton(ctx, {
			name = app.services.settings.values.isMuted ? "mute" : "volume",
			size = theme:px(22),
			onClick = { type = "mute" }
		})),
		slider.view(app, {
			width = sliderWidth,
			value = value,
			min = 0,
			max = 1,
			onchange = volumeChanged,
			-- Every volume control shows the one setting; naming the settings service lets the
			-- two the desktop draws share a draw only where they show the same thing.
			instance = app.services.settings,
			trackColour = theme:color("text", 0.12),
			fillColour = theme:color("muted"),
			thumbColour = theme:color("text"),
			thumbSize = theme:px(12)
		})
	})
end

return volume
