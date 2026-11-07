-- The beat brand mark: its own five bars, not an Ionicons glyph. It is drawn rather than taken
-- from the icon face so the shell's logo stays the artwork the app was designed around.
local wonderland = require("wonderland")

local div, sty = wonderland.div, wonderland.sty

local logo = {}

---@class beat.components.LogoProps
---@field size number # The square the mark is drawn in
---@field colour string # The bars' fill

---@param app beat.App
---@param props beat.components.LogoProps
---@return wonderland.Element
function logo.view(app, props)
	local size, colour = props.size, props.colour

	-- The five bars of the original beat mark, in the 512-unit space of the icon that was used
	-- before the rest of the set moved to Ionicons.
	return div():style(sty():size(size, size)):canvas(function(canvas)
		local unit = math.min(canvas.width, canvas.height) / 512
		local function x(value) return value * unit end
		local function bar(left, top, height)
			local width = x(43)
			canvas:rect(x(left), x(top), width, x(height), colour, width / 2)
		end

		bar(64, 213, 86)
		bar(149, 128, 256)
		bar(235, 43, 426)
		bar(320, 128, 256)
		bar(405, 213, 86)
	end)
end

return logo
