-- The first launch, before a music folder is chosen: one card in the middle of the window, saying
-- what beat is and then letting the folder be picked, either in the system's own dialog or in the
-- in-app browser. The card is a dialog panel, so the first screen already reads like the rest of
-- the app rather than like a page with its chrome taken away.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local cache = require("beat-ui.cache")
local measure = require("beat.app.components.helpers.measure")
local metrics = require("beat.app.components.helpers.metrics")
local logo = require("beat.app.components.logo")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local onboarding = {}

local WELCOME_TITLE = "Welcome to beat"
local WELCOME_COPY = "Point beat at your music and it builds your library as you listen."
local WELCOME_HINT = "You can change the folder later in Settings."
local BROWSE_LABEL = "Browse folders"

-- The two actions of the welcome step. A click on either only sends one of these; nothing here
-- reads the app, so one table serves every frame.
local CHOOSE_FOLDER = { type = "chooseFolder" }
local BROWSE_FOLDERS = { type = "onboardingBrowse" }

---@class beat.components.OnboardingStyles
---@field screen wonderland.StyleBuilder
---@field card wonderland.StyleBuilder
---@field header wonderland.StyleBuilder
---@field title wonderland.StyleBuilder
---@field copy wonderland.StyleBuilder
---@field actions wonderland.StyleBuilder
---@field hint wonderland.StyleBuilder

--- The style the welcome copy is measured in, before the box that holds it is known.
---@param ctx beat.ui.Context
local function copyMeasureStyle(ctx)
	return ctx:s():text(ctx:type("sm")):fg(ctx:color("muted"))
end

--- The screen, the card and the welcome step's boxes. Wonderland fills the main axis for a box
--- that does not state its own length, so every box here is told its height: the welcome card is
--- as tall as its words and buttons, and the browser's card is as tall as its rows.
---@param ctx beat.ui.Context
---@param width number
---@param height number
---@param pad number
---@param gap number
---@param logSize number
---@param titleSize number
---@param titleHeight number
---@param headerHeight number
---@param actionsHeight number
---@param hintHeight number
---@param inner number
---@param copyHeight number
---@return beat.components.OnboardingStyles
local function onboardingStyles(ctx, width, height, pad, gap, logSize, titleSize, titleHeight, headerHeight, actionsHeight, hintHeight, inner, copyHeight)
	local small = ctx:type("sm")
	local copyStyle = ctx:s():w(inner):h(copyHeight):text(small):fg(ctx:color("muted")):justify("center")
	return {
		screen = sty()
			:fill():column():align("center"):justify("center")
			:pad(ctx:space(16)):bg(ctx:color("bg")):fg(ctx:color("text")):font(ctx.theme.fontFamily),
		card = sty()
			:w(width):h(height):column():justify("center"):pad(pad):gap(gap)
			:radius(ctx:radius("md")):bg(ctx:color("elevated")):border(ctx:px(1), ctx:color("border"))
			:shadow(0, ctx:px(12), ctx:px(30), "#00000099"),
		header = sty():w(inner):h(headerHeight):column():align("center"):gap(ctx:space(10)),
		title = ctx:s():w(inner):h(titleHeight):text(titleSize):weight("bold"):fg(ctx:color("text")):justify("center"):ellipsis(),
		copy = copyStyle,
		actions = sty():w(inner):h(actionsHeight):column():align("center"):gap(ctx:space(8)),
		hint = ctx:s():w(inner):h(hintHeight):text(ctx:type("xs")):fg(ctx:color("faint")):justify("center"):ellipsis()
	}
end

---@class beat.components.OnboardingCopy
---@field width number
---@field size number
---@field text string
---@field measured boolean
---@field height number

-- The welcome line, broken to the card by measure, which keeps its lines by width and size. The
-- joined string and the height it draws at are kept beside them: a frame reuses both instead of
-- breaking the copy again. One record per theme, because a scale or a family moves the breaks.
---@type table<beat.Theme, beat.components.OnboardingCopy>
local copyCache = setmetatable({}, { __mode = "k" })
---@param app beat.App
---@param ctx beat.ui.Context
---@param inner number
---@return string
---@return number
local function welcomeCopy(app, ctx, inner)
	local size = ctx:type("sm")
	local lineHeight = math.floor(size * 1.35)
	local theme = ctx.theme
	local memo = copyCache[theme]
	-- The first frame can be built before the window's font manager exists. `measure.wrap` would
	-- then break the line by character estimate and keep that break for good, so the provisional
	-- frame draws the copy whole and the memo says it was not measured: the next frame, with the
	-- font, breaks it to the card and keeps that.
	local measured = app.layoutPlugin ~= nil
	if memo == nil or memo.width ~= inner or memo.size ~= size or memo.text == nil or (memo.measured ~= true and measured) then
		local style = copyMeasureStyle(ctx)
		local lines = measured and measure.wrap(app, WELCOME_COPY, style, size, inner, 3) or { WELCOME_COPY }
		local value = table.concat(lines, "\n")
		local run = measured and measure.run(app, value, style) or nil
		memo = {
			width = inner,
			size = size,
			text = value,
			measured = measured,
			height = run ~= nil and math.floor(run.height + 0.5) or (#lines * lineHeight)
		}
		copyCache[theme] = memo
	end
	return memo.text, memo.height
end

--- The step the first launch is on: the welcome, or the folder browser the welcome leads to.
---@param app beat.App
---@param page beat.PageInstance
---@param window wonderland.RenderWindow
---@param browserView fun(app: beat.App, page: beat.PageInstance, window: wonderland.RenderWindow, width: number, height: number): wonderland.Element, number
---@return wonderland.Element
function onboarding.view(app, page, window, browserView)
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local mobile = metrics.mobile(app, window.width)
	local outer = metrics.pad(app, window.width)
	local width = math.min(theme:px(560), window.width - outer * 2)
	local pad = mobile and theme:space(24) or theme:space(32)
	local inner = width - pad * 2
	local gap = mobile and theme:space(18) or theme:space(22)
	local logSize = theme:px(mobile and 56 or 64)
	local buttonWidth = math.min(inner, theme:px(260))
	local titleSize = theme:type("xxl")
	local titleHeight = math.floor(titleSize * 1.35)
	local hintHeight = math.floor(theme:type("xs") * 1.4)
	local headerGap = theme:space(10)
	local actionsHeight = theme:px(40) + theme:space(8) + theme:px(32)
	local maxHeight = window.height - outer * 2

	if page.state.step == "welcome" then
		-- A phone's card leaves the copy a little narrower than the card, so the line does not break
		-- with one short word alone under it.
		local copy, copyHeight = welcomeCopy(app, ctx, mobile and math.min(inner, theme:px(300)) or inner)
		local headerHeight = logSize + headerGap * 2 + titleHeight + copyHeight
		-- The welcome is a short panel: as tall as its words and buttons with a little air, rather
		-- than the window's height. The browser below needs the room, so it is the taller card.
		local height = math.min(maxHeight, headerHeight + actionsHeight + hintHeight + gap * 2 + pad * 2 + theme:space(40))
		local styles = cache.of(
			ctx,
			onboardingStyles,
			"onboardingWelcome",
			width,
			height,
			pad,
			gap,
			logSize,
			titleSize,
			titleHeight,
			headerHeight,
			actionsHeight,
			hintHeight,
			inner,
			copyHeight
		) --[[@as beat.components.OnboardingStyles]]
		local primary = ui.button(
			ctx,
			{ label = "Choose music folder", onClick = CHOOSE_FOLDER, variant = "primary", width = buttonWidth, height = theme:px(40) }
		)
		local browse = ui.button(ctx, { label = BROWSE_LABEL, onClick = BROWSE_FOLDERS, variant = "quiet", height = theme:px(32) })
		local card = div():style(styles.card):children({
			div():style(styles.header):children({
				logo.view(app, { size = logSize, colour = theme:color("accent") }),
				text(WELCOME_TITLE):style(styles.title),
				text(copy):style(styles.copy)
			}),
			div():style(styles.actions):children({ primary, browse }),
			text(WELCOME_HINT):style(styles.hint)
		})
		return div():style(styles.screen):children({ card })
	end

	-- The browser states the height its whole rows come to, so the card is the panel around what is
	-- drawn rather than a fixed slab with the last row cut off.
	local browser, browserHeight = browserView(app, page, window, inner, math.min(maxHeight, theme:px(mobile and 640 or 600)) - pad * 2)
	local height = math.min(maxHeight, browserHeight + pad * 2)
	local styles = cache.of(
		ctx,
		onboardingStyles,
		"onboardingBrowser",
		width,
		height,
		pad,
		gap,
		logSize,
		titleSize,
		titleHeight,
		headerGap,
		actionsHeight,
		hintHeight,
		inner,
		math.floor(theme:type("sm") * 1.35)
	) --[[@as beat.components.OnboardingStyles]]
	local card = div():style(styles.card):children({ browser })
	return div():style(styles.screen):children({ card })
end

return onboarding
