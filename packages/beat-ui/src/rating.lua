-- A row of stars that shows a rating and sets one. Star n sends the message for n stars; the star
-- already at the rating sends the one for none, so a rating is taken back the way it was given,
-- with no separate clear control. Like the check box it keeps no state: what it draws is the
-- value it is given, and the message is the caller's.
local wonderland = require("wonderland")
local icon = require("beat-ui.icon")
local cache = require("beat-ui.cache")

local div, sty = wonderland.div, wonderland.sty

local rating = {}

local STARS = 5

---@class beat.ui.RatingProps
---@field value number # 0 to 5; 0 is unrated
---@field onRate fun(stars: number): any # The message for a click that sets this many stars, 0 to take the rating away
---@field size number? # One star; default px(16)
---@field gap number? # Between stars; default px(2)
---@field colour string? # A set star; default the accent

---@class beat.ui.RatingStyles
---@field star wonderland.StyleBuilder
---@field row wonderland.StyleBuilder

--- A rating is one star size and one gap, so the star box and the row are made once.
---@param ctx beat.ui.Context
---@param size number
---@param gap number
---@return beat.ui.RatingStyles
local function ratingStyles(ctx, size, gap)
	return {
		star = sty():size(size, size):align("center"):justify("center"),
		row = sty():row():h(size):w(size * STARS + gap * (STARS - 1)):gap(gap):align("center")
	}
end

---@param ctx beat.ui.Context
---@param props beat.ui.RatingProps
---@return wonderland.Element
function rating.view(ctx, props)
	local size = props.size or ctx:px(16)
	local gap = props.gap or ctx:px(2)
	local value = math.max(0, math.min(STARS, math.floor(props.value or 0)))
	local set = props.colour or ctx:color("accent")
	local unset = ctx:color("faint")

	local styles = cache.of(ctx, ratingStyles, "rating", size, gap) --[[@as beat.ui.RatingStyles]]

	local stars = {}
	for at = 1, STARS do
		local on = at <= value
		stars[at] = div():style(styles.star):onClick(props.onRate(at == value and 0 or at)):children({
			icon.view(ctx, { name = on and "star" or "starOutline", size = size, colour = on and set or unset })
		})
	end

	return div():style(styles.row):children(stars)
end

return { view = rating.view }
