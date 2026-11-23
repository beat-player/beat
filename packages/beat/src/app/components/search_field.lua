-- The search pill: a magnifier, a field, and a clear mark once something is typed. The top bar
-- draws one, and a phone's search page draws one where it has no top bar field to type into.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local cache = require("beat-ui.cache")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local searchField = {}

---@param value string
---@return { type: string, value: string }
local function typed(value)
	return { type = "search", value = value }
end

--- The clear mark: a cross drawn in the colour it is given. It is made here so the frame that
--- draws the field defines no function.
---@param colour string
---@param weight number
---@param px4 number # How far each arm reaches, which is scaled by the theme
---@return fun(canvas: wonderland.Canvas)
local function clearDraw(colour, weight, px4)
	return function(canvas)
		local middleX, middleY = canvas.width / 2, canvas.height / 2
		local arm = math.max(3, px4)
		canvas:line(middleX - arm, middleY - arm, middleX + arm, middleY + arm, weight, colour)
		canvas:line(middleX + arm, middleY - arm, middleX - arm, middleY + arm, weight, colour)
	end
end

---@class beat.components.SearchFieldStyles
---@field area wonderland.StyleBuilder
---@field input wonderland.StyleBuilder
---@field field wonderland.StyleBuilder
---@field pill wonderland.StyleBuilder
---@field ring wonderland.StyleBuilder
---@field clearBox wonderland.StyleBuilder
---@field clearDraw fun(canvas: wonderland.Canvas)
---@field textSize number
---@field iconSize number

--- The styles of a pill at a width, a height and a state. They are kept on the theme, so a frame
--- does not intern the same builders again. A tall pill -- the phone's -- sets its text, glyphs
--- and padding larger to match: the same field a size up, not a small field in a big box.
---@param ctx beat.ui.Context
---@param width number
---@param height number
---@param focused boolean
---@param hasClear boolean
---@return beat.components.SearchFieldStyles
local function buildStyles(ctx, width, height, focused, hasClear)
	local large = height >= ctx:px(44)
	local textSize = large and ctx:type("base") or ctx:type("sm")
	local inner = height - ctx:px(large and 8 or 2)
	local side = ctx:px(large and 16 or 12)
	local iconSize = ctx:px(large and 20 or 16)
	local clearSize = ctx:px(large and 28 or 20)
	-- The magnifier, the clear mark and the gaps between them come out of the width the field's
	-- own box gets: what is left is the text.
	local areaWidth = width - side * 2 - iconSize - ctx:px(8) - (hasClear and (clearSize + ctx:px(8)) or 0)
	return {
		area = sty():w(areaWidth):h(inner):row():align("center"),
		input = sty()
			:wrel(1.0):h(inner):row():align("center"):pad(ctx:px(10), 0, ctx:px(10), 0):text(textSize)
			:fg(ctx:color("text")),
		textSize = textSize,
		field = sty():row():wrel(1.0):h(inner):gap(ctx:px(8)):align("center"),
		pill = sty()
			:row():w(width):h(height):radius(ctx:radius("full"))
			:bg(focused and ctx:color("hover") or ctx:color("elevated")):pad(0, side, 0, side):align("center"),
		ring = sty()
			:w(width):h(height):radius(ctx:radius("full")):border(ctx:px(1), ctx:color("accent")):offset(-side, 0),
		clearBox = sty():size(clearSize, clearSize):radius(ctx:radius("full")):align("center"):justify("center"),
		clearDraw = clearDraw(ctx:color("muted"), math.max(1, ctx:px(large and 1.75 or 1.25)), ctx:px(large and 5 or 4)),
		iconSize = iconSize
	}
end

---@class beat.components.SearchFieldProps
---@field name string # The field's focus id
---@field value string
---@field width number
---@field placeholder string
---@field height number? # The pill's height; default px(48) on a phone, px(34) otherwise
---@field clearMessage any? # What the clear mark sends; default a search that empties the query

---@param ctx beat.ui.Context
---@param props beat.components.SearchFieldProps
---@return wonderland.Element
function searchField.view(ctx, props)
	local focused = ctx:focused(props.name)
	local query = props.value
	local hasClear = query ~= ""
	local height = props.height or ctx:px(ctx.mobile and 48 or 34)
	local styles = cache.of(ctx, buildStyles, "searchField", props.width, height, focused, hasClear) --[[@as beat.components.SearchFieldStyles]]
	local shown = hasClear and query or (focused and " " or props.placeholder)
	local colour = hasClear ? (ctx:color("text")) : focused and (ctx:color("text")) or (ctx:color("faint"))

	local input = div():style(styles.input):input({
		name = props.name,
		value = query,
		oninput = typed,
		onsubmit = || -> nil
	})
	input:children(text(shown):style(ctx:s():wrel(1.0):text(styles.textSize):fg(colour):ellipsis()))

	local field = div():style(styles.field):children({
		ui.icon(ctx, { name = "search", size = styles.iconSize, colour = ctx:color("faint") }),
		div():style(styles.area):children({ input })
	})

	if hasClear then
		field:children(div():style(styles.clearBox):onClick(props.clearMessage or { type = "search", value = "" }):canvas(
			styles.clearDraw
		))
	end

	local pill = div():style(styles.pill):children({ field })
	if focused then pill:children(div():style(styles.ring)) end
	return pill
end

return searchField
