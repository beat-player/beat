-- The animated three-bar mark beside a track that is playing now. It is the indicator, not the
-- equalizer: the equalizer measures audio and this only says which row is sounding.
local wonderland = require("wonderland")

local div, sty = wonderland.div, wonderland.sty

local playingBars = {}

---@class beat.components.PlayingBarsProps
---@field playing boolean? # Animates while true; rests at fixed heights otherwise

---@param app beat.App
---@param props beat.components.PlayingBarsProps
---@return wonderland.Element
function playingBars.view(app, props)
	local theme = app.services.appearance.theme
	local colour = theme:color("accent")
	local now = wonderland.time.now()
	local playing = props.playing

	return div():style(sty():size(18, 18)):canvas(function(canvas)
		local bars = { 0.35, 0.75, 0.52}
		local width = canvas.width / 7
		for at = 1, 3 do
			local level = bars[at]
			if playing then
				level = 0.25 + 0.65 * (0.5 + 0.5 * math.sin(now * 7 + at * 1.7))
			end
			local height = math.max(2, math.floor(canvas.height * level))
			canvas:rect((at - 1) * width * 2 + width * 0.5, canvas.height - height, width, height,
			colour, width / 2)
		end
	end)
end

return playingBars
