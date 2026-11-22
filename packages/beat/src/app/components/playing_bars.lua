-- The animated three-bar mark beside a track that is playing now. It is the indicator, not the
-- equalizer: the equalizer measures audio and this only says which row is sounding.
local wonderland = require("wonderland")

local div, sty = wonderland.div, wonderland.sty

local playingBars = {}

-- The heights the mark rests at, and the shape of the wave it moves through while a track plays.
local REST = { 0.35, 0.75, 0.52 }

---@class beat.components.PlayingBarsProps
---@field playing boolean? # Animates while true; rests at fixed heights otherwise

---@param app beat.App
---@param props beat.components.PlayingBarsProps
---@return wonderland.Element
function playingBars.view(app, props)
	local theme = app.services.appearance.theme
	local colour = theme:color("accent")
	local playing = props.playing

	---@type table<string, any>
	local cache = theme:cache()
	local style = cache.playingBars --[[@as wonderland.StyleBuilder?]]
	if style == nil then
		style = sty():size(18, 18)
		cache.playingBars = style
	end

	return div():style(style):canvas(function(canvas)
		-- The clock is read when the mark is drawn rather than when the view was built: a row's
		-- mark keeps moving on the frames a repaint of the screen already built draws, without
		-- the row being laid out again.
		local clock = playing ? wonderland.time.now() : nil
		local width = canvas.width / 7
		for index = 1, 3 do
			local level = REST[index]
			if clock ~= nil then
				level = 0.25 + 0.65 * (0.5 + 0.5 * math.sin(clock * 7 + index * 1.7))
			end
			local height = math.max(2, math.floor(canvas.height * level))
			canvas:rect((index - 1) * width * 2 + width * 0.5, canvas.height - height, width, height, colour, width / 2)
		end
	end)
end

return playingBars
