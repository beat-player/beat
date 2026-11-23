-- A menu that pops out of the control that opened it. It unfolds from the edge nearest that
-- control -- up out of a tab, down out of a button -- so it reads as coming from it, and the edge
-- it grows from stays where it was put.
local wonderland = require("wonderland")

local div, sty = wonderland.div, wonderland.sty

local popup = {}

local DURATION = 0.18

--- Starts the reveal of the popup `key`; called when the overlay it belongs to opens. The clock
--- is brought to the present first: it only moves when the ticker runs, which is every half
--- second while nothing animates, and an animation timed from a stale clock would be over before
--- its first frame. The ticker is woken so the frames between are drawn.
---@param app beat.App
---@param key string
function popup.open(app, key)
	local clock = app.services.motion.clock
	clock:update(wonderland.time.now())
	clock:set(key, 0)
	clock:animate(key, 1, DURATION, app.services.motion.ease.outCubic)
	app:wake()
end

---@class beat.components.PopupProps
---@field key string # The motion key `popup.open` started
---@field panel wonderland.Element # The menu, drawn at `width` by `height`
---@field x number # Where its left edge goes, in the box it is offset from
---@field y number # And its top, once it is fully out
---@field width number
---@field height number
---@field grows "up"|"down" # Which way it comes out of the control: up from a control under it, down from one over it

---@param app beat.App
---@param props beat.components.PopupProps
---@return wonderland.Element
function popup.view(app, props)
	local t = math.max(0, math.min(1, app.services.motion.clock:get(props.key, 1)))
	local width, height = props.width, props.height
	local shown = math.max(1, math.floor(height * t + 0.5))
	if shown >= height then
		return div():style(sty():w(width):h(height):offset(props.x, props.y):z(130)):children({ props.panel })
	end

	-- Part way out, the menu is a window onto the panel that is as tall as how far it has come,
	-- held against the control's edge; the panel slides through it, so its far edge leads.
	local up = props.grows == "up"
	local top = up and (props.y + height - shown) or props.y
	local slide = up and 0 or (shown - height)
	return div()
		:style(sty():w(width):h(shown):offset(props.x, top):z(130)):clip()
		:children({ div():style(sty():w(width):h(height):offset(0, slide)):children({ props.panel }) })
end

return popup
