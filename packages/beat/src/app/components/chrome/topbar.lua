-- The top bar of a desktop: back and forward, the search field, and the way into settings. A
-- phone has no bar of its own: the search page carries a field and the bottom menu has settings.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local cache = require("beat-ui.cache")
local metrics = require("beat.app.components.helpers.metrics")
local searchField = require("beat.app.components.search_field")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local topbar = {}

-- The messages the bar sends, made once: a click hands over the table the element holds.
local BACK = { type = "back" }
local FORWARD = { type = "forward" }
local OPEN_TASKS = { type = "open", overlay = "tasks" }
local OPEN_SETTINGS = { type = "navigate", page = { kind = "settings" } }

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
			name = "queue",
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
	local available = metrics.contentWidth(app, width)
	local tasks = app.services.tasks:tasks()
	local hasTasks = #tasks > 0
	local pillHeight = theme:px(34)
	local iconSize = theme:px(32)
	local gap = theme:px(10)
	local rightWidth = iconSize + (hasTasks and (iconSize + gap) or 0)
	local leftWidth = available - rightWidth - gap
	local searchWidth = leftWidth - theme:px(84)

	local search = app.services.search.query
	local placeholder = metrics.units(app, width) < 480 and "Search" or "Search artists, albums, tracks"
	local leftChildren = {
		navButton(ctx, iconSize, "chevronLeft", BACK, #app.history > 0),
		navButton(ctx, iconSize, "chevronRight", FORWARD, #app.future > 0),
		searchField.view(ctx, { name = "search", value = search, width = searchWidth, placeholder = placeholder })
	}
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
