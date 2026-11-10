-- The list behind the top bar's task button: every task the app is running, how far each has got,
-- and the one thing that can be done about it -- cancel it, or dismiss a failure. It is a light
-- popover like the queue and the sort menu: a press outside it closes it, and the controls take
-- the messages they send rather than letting the press close the panel first.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local Scroll = require("beat.app.services.scroll")
local format = require("beat.app.components.helpers.format")
local metrics = require("beat.app.components.helpers.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local STATE = {
	running = "Running",
	cancelling = "Cancelling…",
	done = "Done",
	failed = "Failed",
	cancelled = "Cancelled"
}

---@type beat.OverlaySurface
local tasksPanel = { light = true }

function tasksPanel.new()
	return {}
end

--- The panel's own controls and the scroll it does itself. A light overlay closes on a message it
--- does not take, so the messages that belong to a task are handed to the tasks service here.
---@param app beat.App
---@param overlay beat.OverlayInstance
---@param message beat.Message
function tasksPanel.update(app, overlay, message)
	if message.type == "open" and message.overlay == "tasks" then
		app:close(overlay)
		return true
	elseif message.type == "taskCancel" or message.type == "taskDismiss" then
		app:toService(message)
		app:refresh()
		return true
	elseif message.type == "scroll" and message.key == "tasks" then
		app:toService(message)
		app:refresh()
		return true
	end
	return false
end

--- One task: what it is doing, how far it has got, and the button that ends it or puts its failure
--- away. A task without a cancel message has no Cancel button, because there is nothing to hear.
---@param app beat.App
---@param ctx beat.ui.Context
---@param task beat.Task
---@param width number
---@param height number
local function taskRow(app, ctx, task, width, height)
	local theme = app.services.appearance.theme
	local gap = theme:px(10)
	local actionWidth = theme:px(76)
	local actionHeight = theme:px(24)
	local action
	if task.state == "running" and task.cancel ~= nil then
		action = ui.button(
			ctx,
			{ label = "Cancel", onClick = { type = "taskCancel", id = task.id }, height = actionHeight, width = actionWidth }
		)
	elseif task.state == "failed" then
		action = ui.button(
			ctx,
			{ label = "Dismiss", onClick = { type = "taskDismiss", id = task.id }, height = actionHeight, width = actionWidth }
		)
	end

	local textWidth = width - (action ~= nil and (actionWidth + gap) or 0)
	local detail = task.detail or STATE[task.state] or ""
	local textTone = task.state == "failed" and "danger"
		or task.state == "done" and "success"
		or task.state == "running" and "muted"
		or "faint"
	local barTone = task.state == "failed" and "danger"
		or task.state == "done" and "success"
		or task.state == "cancelled" and "muted"
		or "accent"
	local fraction = task.state == "done" and 1 or task.progress
	local moving = fraction == nil and (task.state == "running" or task.state == "cancelling")

	local column = div()
		:style(sty():column():w(textWidth):h(height):justify("center"):gap(theme:px(4)))
		:children(
			{
				text(task.title):style(theme:s():w(textWidth):text(theme:type("sm")):weight("semibold"):fg(theme:color("text")):ellipsis()),
				text(detail):style(theme:s():w(textWidth):text(theme:type("xs")):fg(theme:color(textTone)):ellipsis()),
				ui.progressBar(
					ctx,
					{
						value = fraction,
						indeterminate = moving,
						width = textWidth,
						height = theme:px(4),
						tone = barTone
					}
				)
			}
		)

	local children = { column }
	if action ~= nil then children[#children + 1] = action end
	return div():style(sty():row():w(width):h(height):gap(gap):align("center")):children(children)
end

---@param app beat.App
---@param _overlay beat.OverlayInstance
---@param window wonderland.RenderWindow
---@return wonderland.Element
function tasksPanel.view(app, _overlay, window)
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local tasks = app.services.tasks:tasks()
	local mobile = ctx.mobile
	local margin = metrics.pad(app, window.width)
	-- The panel hangs under the task button, which sits left of settings in the top bar.
	local right = margin + theme:px(mobile ? 40 : 32) + theme:px(10)
	local top = metrics.topbarHeight(app, window.width) + theme:space(8)
	local width = math.max(theme:px(160), math.min(theme:px(360), window.width - right - margin))
	local padding = theme:px(12)
	local gap = theme:px(8)
	local headerHeight = theme:px(24)
	local rowHeight = theme:px(76)
	local rowStep = rowHeight + theme:px(6)
	local inner = width - padding * 2
	local room = math.max(rowHeight, window.height - top - margin - padding * 2 - headerHeight - gap)
	local full = #tasks * rowStep
	local listHeight = math.max(rowHeight, math.min(full, room))
	local scrollMax = math.max(0, full - listHeight)
	local offset = math.min(app.services.scroll:offset("tasks"), scrollMax)
	local height = padding * 2 + headerHeight + gap + listHeight
	local barWidth = theme:px(6)
	local listWidth = scrollMax > 0 and (inner - barWidth) or inner

	local header = div()
		:style(sty():row():wrel(1.0):h(headerHeight):align("center"):justify("space-between"))
		:children(
			{
				text("Tasks"):style(theme:s():text(theme:type("md")):weight("bold"):fg(theme:color("text"))),
				text(format.count(#tasks, "task")):style(theme:s():text(theme:type("xs")):fg(theme:color("muted")))
			}
		)

	local list = {}
	if #tasks == 0 then
		list[1] = div()
			:style(sty():row():w(listWidth):h(rowHeight):align("center"))
			:children(text("Nothing running"):style(theme:s():text(theme:type("sm")):fg(theme:color("muted"))))
	else
		local first, last, place = Scroll.slices(#tasks, 1, rowStep, offset, listHeight)
		if place > 0 then list[#list + 1] = div():style(sty():w(listWidth):h(place)) end
		for at = first, last do
			local task = tasks[at]
			list[#list + 1] = div()
				:style(sty():w(listWidth):h(rowStep))
				:children({ taskRow(app, ctx, task, listWidth, rowHeight) })
		end
		local bottom = full - place - (last - first + 1) * rowStep
		if bottom > 0 then list[#list + 1] = div():style(sty():w(listWidth):h(bottom)) end
	end

	local rows = {
		header,
		div()
			:style(sty():column():w(inner):h(listHeight):bar(barWidth, theme:px(32), theme:color("faint"))):scroll(offset)
			:onScroll(|by, to| -> { type = "scroll", key = "tasks", max = scrollMax, by = by, to = to }):children(list)
	}

	local panel = div()
		:style(
			sty()
				:w(width):h(height):column():pad(padding):gap(gap):radius(theme:radius("md")):bg(theme:color("elevated"))
				:border(theme:px(1), theme:color("border")):shadow(0, theme:px(12), theme:px(30), "#00000099")
		):onClick({ type = "keep" }):children(rows)

	return div()
		:style(
			sty()
				:fill():offset(0, 0):z(70):row():align("start"):justify("end")
				:pad(top, right, 0, 0)
		):onClick({ type = "dismiss" }):children({ panel })
end

return tasksPanel
