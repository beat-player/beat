-- The top bar: back and forward, the search field, and the way into settings.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local cache = require("beat-ui.cache")
local metrics = require("beat.app.components.helpers.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local topbar = {}

-- The messages the bar sends, made once: a click hands over the table the element holds.
local BACK = { type = "back" }
local FORWARD = { type = "forward" }
local CLEAR_SEARCH = { type = "search", value = "" }
local OPEN_TASKS = { type = "open", overlay = "tasks" }
local OPEN_SETTINGS = { type = "navigate", page = { kind = "settings" } }

---@param value string
---@return { type: string, value: string }
local function searchTyped(value)
	return { type = "search", value = value }
end

--- The search field's clear mark: a cross drawn in the colour it is given. It is made here so the
--- frame that draws the top bar defines no function.
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

---@class beat.components.chrome.TasksStyles
---@field content wonderland.StyleBuilder
---@field glyph wonderland.StyleBuilder
---@field badge wonderland.StyleBuilder
---@field badgeText wonderland.StyleBuilder

---@param ctx beat.ui.Context
---@param size number
---@param glyphSize number
---@param badgeSize number
---@return beat.components.chrome.TasksStyles
local function tasksStyles(ctx, size, glyphSize, badgeSize)
	return {
		content = sty():size(size, size),
		glyph = sty():size(glyphSize, glyphSize):offset((size - glyphSize) / 2, (size - glyphSize) / 2),
		badge = sty()
			:size(badgeSize, badgeSize):radius(ctx:radius("full")):offset(size - badgeSize - ctx:px(1), ctx:px(1))
			:bg(ctx:color("accent")):align("center"):justify("center"),
		badgeText = ctx:s():text(ctx:type("xs")):weight("bold"):fg(ctx.accentInk)
	}
end

---@param ctx beat.ui.Context
---@param barWidth number
---@param barHeight number
---@param size number
---@return wonderland.StyleBuilder
local function tasksTrackStyle(ctx, barWidth, barHeight, size)
	return sty()
		:w(barWidth):h(barHeight):radius(ctx:radius("full")):bg(ctx:color("text", 0.16))
		:offset(ctx:px(4), size - barHeight - ctx:px(2))
end

---@param ctx beat.ui.Context
---@param searchAreaWidth number
---@return wonderland.StyleBuilder
local function searchAreaStyle(ctx, searchAreaWidth)
	return sty():w(searchAreaWidth):h(ctx:px(32)):row():align("center")
end

---@param ctx beat.ui.Context
---@return wonderland.StyleBuilder
local function searchInputStyle(ctx)
	return sty()
		:wrel(1.0):h(ctx:px(32)):row():align("center"):pad(ctx:px(10), 0, ctx:px(10), 0):text(ctx:type("sm"))
		:fg(ctx:color("text"))
end

---@param ctx beat.ui.Context
---@param colour string
---@return wonderland.StyleBuilder
local function searchTextStyle(ctx, colour)
	return ctx:s():wrel(1.0):text(ctx:type("sm")):fg(colour):ellipsis()
end

---@param ctx beat.ui.Context
---@return wonderland.StyleBuilder
local function fieldSearchStyle(ctx)
	return sty():row():wrel(1.0):h(ctx:px(32)):gap(ctx:px(8)):align("center")
end

---@class beat.components.chrome.ClearStyles
---@field box wonderland.StyleBuilder
---@field draw fun(canvas: wonderland.Canvas)

---@param ctx beat.ui.Context
---@return beat.components.chrome.ClearStyles
local function clearStyles(ctx)
	return {
		box = sty():size(ctx:px(20), ctx:px(20)):radius(ctx:radius("full")):align("center"):justify("center"),
		draw = clearDraw(ctx:color("muted"), math.max(1, ctx:px(1.25)), ctx:px(4))
	}
end

---@param ctx beat.ui.Context
---@param searchWidth number
---@param pillHeight number
---@param focused boolean
---@return wonderland.StyleBuilder
local function pillStyle(ctx, searchWidth, pillHeight, focused)
	return sty()
		:row():w(searchWidth):h(pillHeight):radius(ctx:radius("full"))
		:bg(focused and ctx:color("hover") or ctx:color("elevated")):pad(0, ctx:px(12), 0, ctx:px(12)):align("center")
end

---@param ctx beat.ui.Context
---@param searchWidth number
---@param pillHeight number
---@return wonderland.StyleBuilder
local function ringStyle(ctx, searchWidth, pillHeight)
	return sty()
		:w(searchWidth):h(pillHeight):radius(ctx:radius("full")):border(ctx:px(1), ctx:color("accent")):offset(-ctx:px(12), 0)
end

---@param ctx beat.ui.Context
---@param leftWidth number
---@param pillHeight number
---@return wonderland.StyleBuilder
local function leftStyle(ctx, leftWidth, pillHeight)
	return sty():row():w(leftWidth):h(pillHeight):gap(ctx:px(10)):align("center")
end

---@param ctx beat.ui.Context
---@param rightWidth number
---@param pillHeight number
---@return wonderland.StyleBuilder
local function rightStyle(ctx, rightWidth, pillHeight)
	return sty():row():w(rightWidth):h(pillHeight):gap(ctx:px(10)):align("center"):justify("end")
end

---@param ctx beat.ui.Context
---@param topbarHeight number
---@param pad number
---@param inset number # The status bar's height, which the controls sit below
---@return wonderland.StyleBuilder
local function barStyle(ctx, topbarHeight, pad, inset)
	return sty()
		:row():wrel(1.0):h(topbarHeight):pad(inset, pad, 0, pad):gap(ctx:px(10)):align("center"):justify("space-between")
end

--- The task list's button: an icon with how many tasks there are, and the progress of the one
--- running task when there is only one. It is absent when there are no tasks, so the top bar does
--- not have a control with nothing behind it.
---@param app beat.App
---@param ctx beat.ui.Context
---@param size number # The hit area
local function tasksButton(app, ctx, size)
	local theme = app.services.appearance.theme
	local list = app.services.tasks:tasks()
	local count = #list
	local running, runningCount = nil, 0
	for _, task in ipairs(list) do
		if task.state == "running" then
			runningCount += 1
			if running == nil then running = task end
		end
	end

	local glyphSize = math.max(16, math.floor(size * 0.58 + 0.5))
	local badgeSize = math.max(theme:px(14), math.floor(size * 0.46 + 0.5))
	local set = cache.of(ctx, tasksStyles, "topbarTasks", size, glyphSize, badgeSize) --[[@as beat.components.chrome.TasksStyles]]

	local content = div():style(set.content)
	content:children({
		div():style(set.glyph):children(ui.icon(ctx, {
			name = "playlists",
			size = glyphSize,
			colour = runningCount > 0 and theme:color("text") or theme:color("muted")
		})),
		div():style(set.badge):children(text(count > 9 and "9+" or tostring(count)):style(set.badgeText))
	})

	if runningCount == 1 and running ~= nil then
		local barWidth = size - theme:px(8)
		local barHeight = theme:px(3)
		local fraction = running.progress
		local filled = barWidth * (fraction ~= nil and fraction or 0.3)
		local track = cache.of(ctx, tasksTrackStyle, "topbarTasksBar", barWidth, barHeight, size) --[[@as wonderland.StyleBuilder]]
		-- The filled part is as wide as the task has got, which is a value that moves: its width is
		-- the one number of the bar that cannot be shared, so it is made from the value as before.
		local bar = div():style(track):clip():children({
			div():style(sty():w(filled):hrel(1.0):radius(theme:radius("full")):bg(theme:color("accent")))
		})
		content:children({ bar })
	end

	return ui.iconButton(ctx, { size = size, onClick = OPEN_TASKS, content = content })
end

---@param ctx beat.ui.Context
---@param size number
---@param name string
---@param action beat.Message
---@param enabled boolean
---@return wonderland.Element
local function navButton(ctx, size, name, action, enabled)
	return ui.iconButton(ctx, { name = name, size = size, onClick = enabled and action or nil, active = enabled })
end

---@class beat.components.chrome.TopbarProps
---@field width number # The window's width
---@field ui beat.ui.Context

---@param app beat.App
---@param props beat.components.chrome.TopbarProps
---@return wonderland.Element
function topbar.view(app, props)
	local width = props.width
	local ctx = props.ui
	local theme = app.services.appearance.theme
	local mobile = metrics.mobile(app, width)
	local focused = app.layoutPlugin ~= nil and app.window ~= nil and app.layoutPlugin:getFocusedId(app.window) == "search"
	local search = app.services.search.query
	local available = metrics.contentWidth(app, width)
	local tasks = app.services.tasks:tasks()
	local hasTasks = #tasks > 0
	local pillHeight = (theme:px(mobile ? 38 : 34))
	local iconSize = (theme:px(mobile ? 40 : 32))
	local gap = theme:px(10)
	local rightWidth = iconSize + (hasTasks and (iconSize + gap) or 0)
	local leftWidth = available - rightWidth - gap
	local searchWidth = leftWidth - (theme:px(mobile ? 50 : 84))

	local searchAreaWidth = searchWidth - theme:px(24) - theme:px(16) - theme:px(8) - (search ~= "" and theme:px(28) or 0)
	local searchBoxStyle = cache.of(ctx, searchAreaStyle, "topbarSearchArea", searchAreaWidth) --[[@as wonderland.StyleBuilder]]
	local searchArea = div():style(searchBoxStyle)
	local searchText = search ~= "" and search or (focused and " " or (metrics.units(app, width) < 480 and "Search" or "Search artists, albums, tracks"))
	local searchColour = search ~= "" ? (theme:color("text")) : focused and (theme:color("text")) or (theme:color("faint"))

	local inputStyle = cache.of(ctx, searchInputStyle, "topbarSearchInput") --[[@as wonderland.StyleBuilder]]
	local textStyle = cache.of(ctx, searchTextStyle, "topbarSearchText", searchColour) --[[@as wonderland.StyleBuilder]]
	local searchInput = div():style(inputStyle):input({ name = "search", value = search, oninput = searchTyped })
	searchInput:children(text(searchText):style(textStyle))

	searchArea:children({ searchInput })

	local fieldStyle = cache.of(ctx, fieldSearchStyle, "topbarField") --[[@as wonderland.StyleBuilder]]
	local field = div():style(fieldStyle):children({
		ui.icon(ctx, { name = "search", size = theme:px(16), colour = theme:color("faint") }),
		searchArea
	})

	if search ~= "" then
		local clear = cache.of(ctx, clearStyles, "topbarClear") --[[@as beat.components.chrome.ClearStyles]]
		field:children(div():style(clear.box):onClick(CLEAR_SEARCH):canvas(clear.draw))
	end

	local searchStyle = cache.of(ctx, pillStyle, "topbarPill", searchWidth, pillHeight, focused) --[[@as wonderland.StyleBuilder]]

	local searchPill = div():style(searchStyle):children(field)
	if focused then
		-- A focus ring is painted over the pill rather than styled onto it: a border that takes
		-- part in layout shrinks the content box by a pixel and makes the field jump when focus
		-- arrives. The ring is outside the flow and the field keeps its exact position.
		local ring = cache.of(ctx, ringStyle, "topbarRing", searchWidth, pillHeight) --[[@as wonderland.StyleBuilder]]
		searchPill:children(div():style(ring))
	end

	local leftChildren = { navButton(ctx, iconSize, "chevronLeft", BACK, #app.history > 0) }
	if not mobile then
		leftChildren[#leftChildren + 1] = navButton(ctx, iconSize, "chevronRight", FORWARD, #app.future > 0)
	end
	leftChildren[#leftChildren + 1] = searchPill
	local leftBox = cache.of(ctx, leftStyle, "topbarLeft", leftWidth, pillHeight) --[[@as wonderland.StyleBuilder]]
	local left = div():style(leftBox):children(leftChildren)

	local rightChildren = {}
	if hasTasks then rightChildren[#rightChildren + 1] = tasksButton(app, ctx, iconSize) end
	rightChildren[#rightChildren + 1] = ui.iconButton(ctx, { name = "settings", size = iconSize, onClick = OPEN_SETTINGS })
	local rightBox = cache.of(ctx, rightStyle, "topbarRight", rightWidth, pillHeight) --[[@as wonderland.StyleBuilder]]
	local right = div():style(rightBox):children(rightChildren)

	local top = cache.of(ctx, barStyle, "topbar", metrics.topbarHeight(app, width), metrics.pad(app, width), metrics.topbarInset(app, width)) --[[@as wonderland.StyleBuilder]]

	return div():style(top):children({ left, right })
end

return topbar
