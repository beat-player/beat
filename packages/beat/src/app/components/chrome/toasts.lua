-- The messages that slide in over the top right corner: a failure and what it was about, or what
-- just happened.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local measure = require("beat.app.components.helpers.measure")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local toasts = {}

---@class beat.components.chrome.ToastsProps
---@field window wonderland.RenderWindow

---@param app beat.App
---@param props beat.components.chrome.ToastsProps
---@return wonderland.Element? overlay
function toasts.view(app, props)
	local window = props.window
	if #app.services.toasts.list == 0 then return nil end
	local theme = app.services.appearance.theme
	local now = wonderland.time.now()
	local children = {}
	local width = math.min(320, window.width - theme:space(16))
	local size = theme:type("sm")
	local textStyle = theme:s():text(size)
	-- The padding either side, the icon and the gap after it.
	local lineWidth = width - theme:px(14) * 2 - theme:px(18) - theme:px(10)
	local top = theme:px(76)
	local scan = app.services.scan
	local scanCard = (scan.job ~= nil and scan.islandOpen and app.services.library.current ~= nil
	and #app.services.library.current.tracks > 0) or scan.summary ~= nil
	if scanCard then top = top + theme:px(112) + theme:space(12) end

	local y = top
	for _, toast in ipairs(app.services.toasts.list) do
			local enter = app.services.motion.clock.reduce and 1
			or ui.motion.progress(toast.at, 0.18, now, ui.motion.ease.outCubic)
			local life = toast.tone == "error" and 8 or 4.5
			local expires = toast.expires or (toast.at + life)
			local exit = app.services.motion.clock.reduce and 1
			or 1 - ui.motion.progress(expires - 0.3, 0.3, now, ui.motion.ease.inCubic)
			-- Both the fade and the lift are quantised so they reuse styles instead of interning
			-- one per frame.
			local enterStep = math.floor(enter * 16 + 0.5) / 16
			local exitStep = math.floor(exit * 16 + 0.5) / 16
			local alpha = math.min(enterStep, exitStep)
			local lift = (1 - enterStep) * theme:px(8) - (1 - exitStep) * theme:px(8)
			local tone = toast.tone == "error" and theme:color("danger", alpha)
			or theme:color("accent", alpha)

			-- A message wraps rather than being cut short: an error is the one toast that has to be
			-- read whole. Five lines is room for a long path and what went wrong with it.
			local message = table.concat(measure.wrap(app, toast.text, textStyle, size, lineWidth, 5), "\n")
			local run = measure.run(app, message, textStyle)
			local _, breaks = message:gsub("\n", "")
			local textHeight = run and run.height or (breaks + 1) * math.floor(size * 1.35 + 0.5)
			local height = math.max(theme:px(48), textHeight + theme:px(12) * 2)
			local x = math.max(theme:space(8), window.width - width - theme:space(24))

			toast.rect = { x = x, y = y, width = width, height = height }

			children[#children + 1] = div()
			:style(sty():w(width):h(height):row():pad(theme:px(12), theme:px(14), theme:px(12), theme:px(14))
			:gap(theme:px(10)):align("center"):radius(theme:radius("sm"))
			:bg(theme:color("elevated", alpha))
			:offset(x, y + lift)
			:shadow(0, theme:px(8), theme:px(24), "#00000040"))
			:onClick({ type = "dismissToast", at = toast.at})
			:children({
			ui.icons.element(toast.tone == "error" and "close" or "check", theme:px(18), tone),
			text(message):style(theme:s():w(lineWidth):h(textHeight):text(size)
			:fg(theme:color("text", alpha))),
			})
			y = y + height + theme:px(8)
		end

	return div():style(sty():fill():offset(0, 0):z(90)):children(children)
end

return toasts
