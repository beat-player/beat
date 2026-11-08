-- The volume control: a mute toggle and a slider over the settings' volume.
local wonderland = require("wonderland")
local iconButton = require("beat.app.components.icon_button")
local slider = require("beat.app.components.slider")

local div, sty = wonderland.div, wonderland.sty

local volume = {}

---@class beat.components.VolumeProps
---@field width number # The whole control, icon and slider together
---@field trackWidth number? # The slider track, when it should line up with another slider's track

---@param app beat.App
---@param props beat.components.VolumeProps
---@return wonderland.Element
function volume.view(app, props)
	local theme = app.services.appearance.theme
	local width = props.width
	local trackWidth = props.trackWidth
	local value = app.services.settings.values.isMuted and 0 or app.services.settings.values.volume
	local iconSlot = trackWidth ~= nil and theme:px(34) or theme:px(22)
	local sliderWidth = trackWidth or (width - theme:px(30))

	return div():style(sty():w(width):h(theme:px(22)):row():align("center"):gap(theme:px(8))):children({
		div():style(sty():w(iconSlot):h(theme:px(22)):row():align("center"):justify("center")):children(
		iconButton.view(app, {
			name = app.services.settings.values.isMuted and "mute" or "volume",
			size = theme:px(22),
			onClick = { type = "mute"},
		})
		),
		slider.view(app, {
			width = sliderWidth,
			value = value,
			min = 0,
			max = 1,
			onchange = function(value_) return { type = "volume", value = value_} end,
			trackColour = theme:color("text", 0.12),
			fillColour = theme:color("muted"),
			thumbColour = theme:color("text"),
			thumbSize = theme:px(12),
		}),
	})
end

return volume
