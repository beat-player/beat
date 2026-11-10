-- The queue, as a panel opened from the now-playing screen's queue button.
local wonderland = require("wonderland")
local format = require("beat.app.components.helpers.format")
local nowPlaying = require("beat.app.overlays.now_playing")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.QueueAnchor
---@field toolWidth number # The tool row's width; the panel is no wider
---@field room beat.ToolRoom

---@class beat.QueueState
---@field anchor beat.QueueAnchor?

---@class beat.QueueOverlay: beat.OverlaySurface
local queuePanel = { light = true, anchored = true }

---@param app beat.App
function queuePanel.new(app)
	-- A queue opens at its next track, not where it was last scrolled to.
	app.services.scroll:reset("queue")
	---@type beat.QueueState
	return {}
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.QueueState>
---@param message beat.Message
function queuePanel.update(app, overlay, message)
	if message.type == "scroll" and message.key == "queue" then
		-- The list scrolls by itself. A light overlay closes on a message it does not take, and
		-- scrolling the queue is not a press elsewhere. It takes the message here, so the redraw
		-- a service's answer gets from the message pump has to be asked for.
		app:toService(message)
		app:refresh()
		return true
	elseif message.type == "toggleQueue" then
		-- The queue button closes what it opened rather than opening a second one.
		app:close(overlay)
		return true
	end
	return false
end

--- The queue is a panel instead of a permanent column, so the cover and controls keep the room
--- on every width. It opens from the queue button, as tall as the queue up to the room on that
--- side of the button, and scrolls past that.
---@param app beat.App
---@param overlay beat.OverlayInstance<beat.QueueState>
---@param _window wonderland.RenderWindow
---@return wonderland.Element?
function queuePanel.view(app, overlay, _window)
	local state = overlay.state
	local anchor = state.anchor
	if anchor == nil then return nil end
	local toolWidth = anchor.toolWidth
	local room = anchor.room
	local theme = app.services.appearance.theme
	local queue = app.services.playback.player.queue
	local upcoming = queue ? (queue:upcoming()) : {}
	local rowHeight = theme:px(48)
	local padding = theme:px(10)
	local headerHeight = theme:px(24)
	local gap = theme:px(4)
	local width = math.min(theme:px(340), toolWidth)
	local inner = width - padding * 2
	local fixed = padding * 2 + headerHeight + gap

	local fullHeight = #upcoming * rowHeight
	local space = math.max(room.below, room.above) - theme:px(6)
	local listHeight = math.max(rowHeight, math.min(fullHeight, space - fixed))
	local height = fixed + listHeight
	local scrollMax = math.max(0, fullHeight - listHeight)
	local offset = math.min(app.services.scroll:offset("queue"), scrollMax)
	-- The bar takes its strip from the rows, so they are narrowed by it rather than run under it.
	local barWidth = theme:px(6)
	local listWidth = scrollMax > 0 and (inner - barWidth) or inner
	local rowPad = theme:px(8)
	local rowGap = theme:px(8)
	local clockWidth = theme:px(44)
	local infoWidth = listWidth - rowPad * 2 - rowGap - clockWidth

	local rows = {}
	rows[#rows + 1] = div()
		:style(sty():row():wrel(1.0):h(headerHeight):align("center"):justify("space-between"))
		:children(
			{
				text("QUEUE"):style(theme:s():text(theme:type("xs")):weight("bold"):fg(theme:color("muted"))),
				text(format.count(#upcoming, "track")):style(theme:s():text(theme:type("xs")):fg(theme:color("faint")))
			}
		)
	if #upcoming == 0 then
		rows[#rows + 1] = div()
			:style(sty():row():wrel(1.0):h(rowHeight):align("center"))
			:children({ text("Nothing queued yet"):style(theme:s():text(theme:type("sm")):fg(theme:color("muted"))) })
	else
		-- Only the rows in view are built, between spacers that keep the list its full height: a
		-- queue can be a whole library.
		local first, last, top = app.services.scroll.slices(#upcoming, 1, rowHeight, offset, listHeight)
		local list = {}
		if top > 0 then list[#list + 1] = div():style(sty():w(listWidth):h(top)) end
		for at = first, last do
			local nextTrack = upcoming[at]
			list[#list + 1] = div()
				:style(
					sty()
						:row():w(listWidth):h(rowHeight):pad(0, rowPad, 0, rowPad):gap(rowGap):align("center"):radius(theme:radius("sm"))
				)
				:hover(
					sty()
						:row():w(listWidth):h(rowHeight):pad(0, rowPad, 0, rowPad):gap(rowGap):align("center"):radius(theme:radius("sm"))
						:bg(theme:color("hover"))
				):onClick({ type = "jumpTrack", trackId = nextTrack.id })
				:children(
					{
						div()
							:style(sty():column():w(infoWidth):h(rowHeight):justify("center"))
							:children(
								{
									text(nextTrack.title)
										:style(theme:s():w(infoWidth):text(theme:type("sm")):weight("semibold"):fg(theme:color("text")):ellipsis()),
									text(nextTrack.artist):style(theme:s():w(infoWidth):text(theme:type("xs")):fg(theme:color("muted")):ellipsis())
								}
							),
						div()
							:style(sty():row():w(clockWidth):h(rowHeight):align("center"):justify("end"))
							:children(
								text(format.clock(nextTrack.duration)):style(theme:s():text(theme:type("xs")):fg(theme:color("faint")))
							)
					}
				)
		end
		local bottom = fullHeight - top - (last - first + 1) * rowHeight
		if bottom > 0 then list[#list + 1] = div():style(sty():w(listWidth):h(bottom)) end

		rows[#rows + 1] = div()
			:style(sty():column():w(inner):h(listHeight):bar(barWidth, theme:px(32), theme:color("faint"))):scroll(offset)
			:onScroll(|by, to| -> { type = "scroll", key = "queue", max = scrollMax, by = by, to = to }):children(list)
	end

	local panel = div()
		:style(
			sty()
				:w(width):h(height):column():pad(padding):gap(gap):radius(theme:radius("md")):bg(theme:color("elevated"))
				:border(theme:px(1), theme:color("border")):shadow(0, theme:px(12), theme:px(30), "#00000099")
		):onClick({ type = "keep" }):children(rows)

	return nowPlaying.toolPanel(app, panel, 0, width, height, room)
end

return queuePanel
