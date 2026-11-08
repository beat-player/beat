-- The volume bubble, opened from the now-playing controls. It is a panel beside the transport
-- rather than a child of the volume button, and the now-playing screen offsets it there.
local wonderland = require("wonderland")
local iconButton = require("beat.app.components.icon_button")
local slider = require("beat.app.components.slider")

local div, sty = wonderland.div, wonderland.sty

---@class beat.VolumeAnchor
---@field width number
---@field height number
---@field x number
---@field y number

---@class beat.VolumeState
---@field anchor beat.VolumeAnchor?

---@class beat.VolumeOverlay: beat.OverlaySurface
local volume = { light = true, anchored = true }

function volume.new()
	---@type beat.VolumeState
	return {}
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.VolumeState>
---@param message beat.Message
function volume.update(app, overlay, message)
	if message.type == "toggleVolume" then
		-- The volume button closes what it opened rather than opening a second bubble.
		app:close(overlay)
		return true
	elseif message.type == "volume" then
		-- The slider is this panel's own control. A light overlay closes on a message it does not
		-- take, so a drag keeps the bubble open and the change is made here.
		app.services.playback:setVolume(message.value)
		return true
	elseif message.type == "mute" then
		app.services.playback:toggleMute()
		return true
	end
	return false
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.VolumeState>
---@param _window wonderland.RenderWindow
---@return wonderland.Element?
function volume.view(app, overlay, _window)
	local state = overlay.state
	local opts = state.anchor
	if opts == nil then return nil end
	local theme = app.services.appearance.theme
	local muted = app.services.settings.values.isMuted
	local padding = theme:px(10)
	local muteSize = theme:px(22)
	local gap = theme:px(8)
	local sliderWidth = opts.width - padding * 2 - muteSize - gap

	return div()
		:style(
			sty()
				:w(opts.width):h(opts.height):offset(opts.x, opts.y):row():align("center"):gap(gap):pad(0, padding, 0, padding)
				:radius(theme:radius("md")):bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
		):onClick({ type = "keep" })
		:children(
			{
				iconButton.view(app, { name = muted ? "mute" : "volume", size = muteSize, onClick = { type = "mute" } }),
				slider.view(
					app,
					{
						width = sliderWidth,
						value = muted ? 0 : app.services.settings.values.volume,
						min = 0,
						max = 1,
						onchange = |value| -> { type = "volume", value = value },
						trackColour = theme:color("text", 0.12),
						fillColour = theme:color("muted"),
						thumbColour = theme:color("text"),
						thumbSize = theme:px(12)
					}
				)
			}
		)
end

return volume
