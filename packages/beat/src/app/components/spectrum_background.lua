-- The spectrum as a quiet background for the playing bar. It is deliberately faint and wide:
-- content sits over it, so this is texture rather than a second meter.
local wonderland = require("wonderland")

local div, sty = wonderland.div, wonderland.sty

local spectrumBackground = {}

---@class beat.components.SpectrumBackgroundProps
---@field intensity number? # Scales the wash's opacity; default 1
---@field reach number? # How much of the bar's height the tallest bar takes; default 0.82

--- The element fills the box it is given and takes no room in it, so a caller can place it as a
--- layer behind its siblings.
---@param app beat.App
---@param props beat.components.SpectrumBackgroundProps
---@return wonderland.Element
function spectrumBackground.view(app, props)
	local intensity = props.intensity or 1
	local reach = props.reach or 0.82
	local theme = app.services.appearance.theme
	local levels = app.services.playback.spectrum ? (app.services.playback.spectrum:values()) : {}
	local active = false
	for at = 1, #levels do
		if levels[at] > 0.01 then active = true; break end
	end

	return div():style(sty():fill():offset(0, 0)):canvas(function(canvas)
		if #levels == 0 or not active then return end

		local count = 72
		local gap = 3
		local barWidth = math.max(1, (canvas.width - gap * (count - 1)) / count)

		for at = 1, count do
			local position = (at - 1) / (count - 1) * (#levels - 1) + 1
			local lower = math.floor(position)
			local upper = math.min(#levels, lower + 1)
			local mix = position - lower
			local level = (levels[lower] or 0) * (1 - mix) + (levels[upper] or 0) * mix
			local barHeight = math.max(2, level * canvas.height * reach)
			local x = (at - 1) * (barWidth + gap)
			local alpha = (0.035 + level * 0.09) * intensity

			-- A wider, nearly transparent pass and a narrower core: at this opacity it reads as a
			-- blurred wash behind the bar rather than a row of hard rectangles.
			canvas:rect(x - 2, canvas.height - barHeight - 1, barWidth + 4, barHeight + 1,
			theme:color("accent", alpha * 0.35), 3)
			canvas:rect(x, canvas.height - barHeight, barWidth, barHeight,
			theme:color("accent", alpha), math.max(1, barWidth / 3))
		end
	end)
end

return spectrumBackground
