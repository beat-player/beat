-- The screen a collection shows when it has nothing in it: a drawn record (or an icon), a title,
-- an explanation, and the one action that fills it.
local wonderland = require("wonderland")
local button = require("beat-ui.button")
local cache = require("beat-ui.cache")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local emptyState = {}

---@class beat.ui.EmptyStateProps
---@field title string
---@field copy string? # The line under the title, wrapped to the window
---@field actionLabel string? # The button's label; omitted with `action`
---@field action any? # The message the button sends
---@field icon string? # An emoji or glyph instead of the drawn record

-- The record's twelve lines say the same thing every time, at the same size: it is drawn per frame,
-- but nothing about it is made there.
local RECORD_SIZE = 120
local RECORD_SEGMENTS = 12

---@param canvas wonderland.Canvas
---@param body string
---@param centre string
---@param line string
---@param weight number
local function drawRecord(canvas, body, centre, line, weight)
	local middleX, middleY = canvas.width / 2, canvas.height / 2
	canvas:circle(middleX, middleY, canvas.width * 0.38, body)
	canvas:circle(middleX, middleY, canvas.width * 0.09, centre)
	for at = 0, RECORD_SEGMENTS - 1 do
		local angle = at / RECORD_SEGMENTS * math.pi * 2
		canvas:line(
			middleX + math.cos(angle) * canvas.width * 0.14,
			middleY + math.sin(angle) * canvas.height * 0.14,
			middleX + math.cos(angle) * canvas.width * 0.25,
			middleY + math.sin(angle) * canvas.height * 0.25,
			weight,
			line
		)
	end
end

--- The record's draw, filled in the theme's colours. It is made here so the view defines no
--- function of its own.
---@param body string
---@param centre string
---@param line string
---@param weight number
---@return fun(canvas: wonderland.Canvas)
local function recordDraw(body, centre, line, weight)
	return function(canvas) drawRecord(canvas, body, centre, line, weight) end
end

---@class beat.ui.EmptyStateStyles
---@field icon wonderland.StyleBuilder
---@field title wonderland.StyleBuilder
---@field copy wonderland.StyleBuilder
---@field row wonderland.StyleBuilder
---@field record fun(canvas: wonderland.Canvas)
---@field recordBox wonderland.StyleBuilder

--- One empty state is on screen at a time, and its colours and sizes are the theme's.
---@param ctx beat.ui.Context
---@param copyWidth number
---@return beat.ui.EmptyStateStyles
local function emptyStateStyles(ctx, copyWidth)
	local body, centre, line = ctx:color("elevated"), ctx:color("accent", 0.55), ctx:color("text", 0.08)
	return {
		icon = ctx:s():text(ctx:px(40)):fg(ctx:color("text")),
		title = ctx:s():text(ctx:type("xl")):weight("bold"):fg(ctx:color("text")),
		copy = ctx:s():w(copyWidth):text(ctx:type("sm")):fg(ctx:color("muted")):align("center"),
		row = sty():fill():column():align("center"):justify("center"):gap(ctx:px(14)),
		record = recordDraw(body, centre, line, ctx:px(2)),
		recordBox = sty():size(RECORD_SIZE, RECORD_SIZE)
	}
end

---@param ctx beat.ui.Context
---@param props beat.ui.EmptyStateProps
---@return wonderland.Element
function emptyState.view(ctx, props)
	local copy, actionLabel, action = props.copy, props.actionLabel, props.action
	local copyWidth = math.min(ctx:px(420), ctx.width - ctx:space(64))
	local styles = cache.of(ctx, emptyStateStyles, "emptyState", copyWidth) --[[@as beat.ui.EmptyStateStyles]]

	local children = {}
	if props.icon ~= nil then
		children[#children + 1] = text(props.icon):style(styles.icon)
	else
		children[#children + 1] = div():style(styles.recordBox):canvas(styles.record)
	end
	children[#children + 1] = text(props.title):style(styles.title)
	if copy ~= nil then children[#children + 1] = text(copy):style(styles.copy) end

	if actionLabel ~= nil and action ~= nil then
		children[#children + 1] = button.view(ctx, {
			label = actionLabel,
			onClick = action,
			variant = "primary",
			width = ctx:px(160)
		})
	end

	return div():style(styles.row):children(children)
end

return { view = emptyState.view }
