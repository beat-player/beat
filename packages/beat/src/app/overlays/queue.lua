-- The queue, as a panel opened from the now-playing screen's queue button.
--
-- The list is also edited here: a row is taken out by the button a pointer reveals, a swipe on a
-- phone, and put somewhere else by dragging it -- after a hold on a phone, from wherever it is
-- pressed on a desktop. The gestures are the overlay's state rather than a service's, because they
-- last only while the panel is open; what they come to is a message, and the queue behind it is
-- the playback service's (see `queueRemove` and `queueMove`).
local wonderland = require("wonderland")
local format = require("beat.app.components.helpers.format")
local metrics = require("beat.app.components.helpers.metrics")
local nowPlaying = require("beat.app.overlays.now_playing")
local popup = require("beat.app.components.popup")
local queueRow = require("beat.app.components.queue_row")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local time = wonderland.time

-- How long a phone's finger rests on a row before it can be dragged: the same sort of hold as a
-- long press anywhere else, and short enough not to feel stuck.
local HOLD = 0.35

-- How far a row slides before it is let go of and taken out of the queue, as a share of its width.
local REMOVE_SHARE = 0.4

-- What a move that only changes a row's place sends: the overlay takes it, refreshes, and nothing
-- else hears it.
local GESTURE = { type = "queueGesture" }

---@class beat.QueueAnchor
---@field toolWidth number # The tool row's width; the panel is no wider
---@field room beat.ToolRoom

---@class beat.QueuePress
---@field index number # The row's 1-based place in the displayed list
---@field x number # Where the press was, across the list
---@field y number # And in the list's own box
---@field contentY number # And in the list's content, which does not move with the scrollbar
---@field at number # When it was pressed, for the hold a phone's drag begins with

---@class beat.QueueState
---@field anchor beat.QueueAnchor?
---@field hover number? # The row a pointer is over
---@field press beat.QueuePress?
---@field drag beat.QueueDrag?
---@field swipe beat.QueueSwipe?
---@field input table? # The list's handlers, made once for this panel
---@field rowProps beat.components.QueueRowProps? # And the props its rows are built from
---@field scrollHandler fun(by: number, to: number): table # The list's scroll message, made once
---@field count number
---@field rowHeight number
---@field listWidth number
---@field listHeight number
---@field scrollOffset number
---@field scrollMax number
---@field mobile boolean
---@field edge number # How near an end of the viewport a drag scrolls the list
---@field autoStep number
---@field dragSlop number
---@field swipeSlop number
---@field holdSlop number
---@field countLabel string?

---@class beat.QueueOverlay: beat.OverlaySurface
local queuePanel = { light = true, anchored = true }

-- The message a row's own press sends, one per track rather than one per row per frame.
---@type table<beat.Track, table>
local jumps = setmetatable({}, { __mode = "k" })

---@param track beat.Track
---@return table
local function jumpFor(track)
	local message = jumps[track]
	if message == nil then
		message = { type = "jumpTrack", trackId = track.id }
		jumps[track] = message
	end
	return message
end

-- The remove message of each displayed place. The place is what the queue displays, so these are
-- kept by it rather than by the track: the same track at another place sends another message.
---@type table<number, table>
local removes = {}

---@param index number
---@return table
local function removeFor(index)
	local message = removes[index]
	if message == nil then
		message = { type = "queueRemove", index = index }
		removes[index] = message
	end
	return message
end

--- Where a point in the list's box is in its content: a row's place and how far into it the point
--- is, whatever the list is scrolled to.
---@param state beat.QueueState
---@param relY number
---@return number
local function contentYAt(state, relY)
	return relY + state.scrollOffset
end

--- The 1-based displayed row a point in the list's content is over.
---@param state beat.QueueState
---@param contentY number
---@return number
local function indexAt(state, contentY)
	local index = math.floor(contentY / state.rowHeight) + 1
	if index < 1 then return 1 end
	if index > state.count then return state.count end
	return index
end

--- The row the stack shows at one slot while a drag is showing where it would land. The lifted
--- row is out of the stack, so the slot it would land on is empty and the rows between its old and
--- new places take the slots the move gives them.
---@param drag beat.QueueDrag?
---@param slot number
---@return number? # The displayed row at the slot; nil for the gap the lifted row would fill
local function slotIndex(drag, slot)
	if drag == nil then return slot end
	if slot == drag.to then return nil end
	if drag.to > drag.index then
		if slot >= drag.index and slot < drag.to then return slot + 1 end
		return slot
	end
	if slot > drag.to and slot <= drag.index then return slot - 1 end
	return slot
end

--- The place a row dragged `dy` pixels would land: it changes place when it passes the middle of
--- the row next to it, which is exactly a row's height of travel.
---@param state beat.QueueState
---@param from number
---@param dy number
---@return number
local function dropIndex(state, from, dy)
	local to = math.floor(from + dy / state.rowHeight + 0.0001)
	if to < 1 then return 1 end
	if to > state.count then return state.count end
	return to
end

--- Scrolls a list a dragged row has been taken to an end of: the content moves the way the hand
--- leans, and the row's own offset in the content moves with it so it stays under the hand. Returns
--- the scroll message the list has to be given, or nil when the hand is not near an end.
---@param state beat.QueueState
---@param drag beat.QueueDrag
---@param relY number
---@return table?
local function edgeScroll(state, drag, relY)
	local dir = 0
	if relY < state.edge and state.scrollOffset > 0 then
		dir = -1
	elseif relY > state.listHeight - state.edge and state.scrollOffset < state.scrollMax then
		dir = 1
	end
	if dir == 0 then return nil end

	local before = state.scrollOffset
	local target = before + dir * state.autoStep
	if target < 0 then target = 0 end
	if target > state.scrollMax then target = state.scrollMax end
	if target == before then return nil end

	state.scrollOffset = target
	drag.dy = drag.dy + (target - before)
	drag.lastDy = drag.dy
	drag.to = dropIndex(state, drag.index, drag.dy)
	return { type = "scroll", key = "queue", max = state.scrollMax, to = target }
end

--- The list's handlers: pressing a row begins whatever gesture it is -- a tap, a slide, a drag --
--- and moving decides which, from how far and how long the pointer has gone. They are made once
--- for the panel, because a handler remade every frame is a closure a frame.
---@param app beat.App
---@param overlay beat.OverlayInstance<beat.QueueState>
---@return { press: function, move: function, release: function }
local function inputFor(app, overlay)
	local state = overlay.state
	local known = state.input
	if known ~= nil then return known end

	---@param relX number
	---@param relY number
	---@return table?
	local function press(relX, relY)
		state.drag, state.swipe, state.press = nil, nil, nil
		if state.count == 0 then return nil end
		local contentY = contentYAt(state, relY)
		if contentY < 0 or contentY >= state.count * state.rowHeight then return nil end

		local index = indexAt(state, contentY)
		state.press = { index = index, x = relX, y = relY, contentY = contentY, at = time.now() }
		if state.hover ~= index then
			state.hover = index
			return { type = "hoverQueue", index = index }
		end
		return nil
	end

	---@param relX number
	---@param relY number
	---@return table?
	local function move(relX, relY)
		-- A release outside the list never reaches the list's release handler, so a moved pointer
		-- with nothing held down is what says the gesture ended: without it a drag would go on
		-- following a pointer nobody is holding.
		local pointer = app.layoutPlugin ~= nil and app.window ~= nil
			and app.layoutPlugin:pointer(app.window) or nil
		if pointer ~= nil and pointer.pressed == false then
			state.press, state.drag, state.swipe = nil, nil, nil
		end
		if state.count == 0 then return nil end

		local contentY = contentYAt(state, relY)
		local index = indexAt(state, contentY)

		local drag = state.drag
		if drag ~= nil then
			local dy = contentY - drag.contentY
			drag.dy = dy
			local to = dropIndex(state, drag.index, dy)
			local moved = to ~= drag.to
			drag.to = to

			-- Held near an end of what is shown, the content is scrolled the way the pointer leans,
			-- and the row keeps its place under the hand as it goes.
			local scroll = edgeScroll(state, drag, relY)
			if scroll ~= nil then return scroll end

			if moved or drag.lastDy ~= dy then
				drag.lastDy = dy
				return GESTURE
			end
			return nil
		end

		local swipe = state.swipe
		if swipe ~= nil then
			swipe.dx = relX - swipe.x
			return GESTURE
		end

		local held = state.press
		if held ~= nil then
			local dx = relX - held.x
			local dy = contentY - held.contentY
			local adx, ady = math.abs(dx), math.abs(dy)

			if state.mobile then
				if adx > state.swipeSlop and adx > ady then
					state.swipe = { index = held.index, x = held.x, dx = dx }
					state.hover = nil
					return GESTURE
				end
				if ady >= state.holdSlop then
					if time.now() - held.at >= HOLD then
						-- The hold has become a drag. The phone says so, if it can.
						state.drag = {
							index = held.index,
							contentY = held.contentY,
							dy = dy,
							lastDy = dy,
							to = dropIndex(state, held.index, dy)
						}
						state.press = nil
						state.hover = nil
						local haptics = app.services.haptics
						if haptics ~= nil then haptics:tick() end
						return edgeScroll(state, assert(state.drag), relY) or GESTURE
					end
					-- Up or down before the hold is the list being scrolled, not a row being moved.
					state.press = nil
					return nil
				end
			elseif ady >= state.dragSlop then
				state.drag = {
					index = held.index,
					contentY = held.contentY,
					dy = dy,
					lastDy = dy,
					to = dropIndex(state, held.index, dy)
				}
				state.press = nil
				state.hover = nil
				return edgeScroll(state, assert(state.drag), relY) or GESTURE
			end
			return nil
		end

		-- Nothing is held: the pointer is only over a row, and the row's button appears with it.
		if state.hover ~= index then
			state.hover = index
			return { type = "hoverQueue", index = index }
		end
		return nil
	end

	---@param relX number
	---@param relY number
	---@return table?
	local function release(relX, relY)
		local drag = state.drag
		if drag ~= nil then
			state.drag = nil
			state.hover = nil
			if drag.to ~= drag.index then
				return { type = "queueMove", from = drag.index, to = drag.to }
			end
			return GESTURE
		end

		local swipe = state.swipe
		if swipe ~= nil then
			state.swipe = nil
			state.press = nil
			if math.abs(swipe.dx) >= state.listWidth * REMOVE_SHARE then
				state.hover = nil
				return removeFor(swipe.index)
			end
			return GESTURE
		end

		local held = state.press
		state.press = nil
		if held == nil then return nil end

		-- A phone's hold is the row being made draggable: a finger that rested that long and was
		-- let go of where it was waiting to move the row, not asking for it to play.
		if state.mobile and time.now() - held.at >= HOLD then return nil end

		-- A press let go of where it landed is the tap that plays a track, as the row's click was.
		local dx = relX - held.x
		local dy = contentYAt(state, relY) - held.contentY
		if math.abs(dx) <= state.swipeSlop and math.abs(dy) <= state.dragSlop then
			local queue = app.services.playback.player.queue
			local orderIndex = queue ~= nil and queue.order[queue.position + held.index] or nil
			local track = orderIndex ~= nil and queue.tracks[orderIndex] or nil
			if track ~= nil then return jumpFor(track) end
		end
		return nil
	end

	known = { press = press, move = move, release = release }
	state.input = known
	return known
end

---@param app beat.App
function queuePanel.new(app)
	-- A queue opens at its next track, not where it was last scrolled to.
	app.services.scroll:reset("queue")
	popup.open(app, "queuePanel")
	---@type beat.QueueState
	local state = { count = 0, rowHeight = 1, listWidth = 1, listHeight = 1, scrollOffset = 0, scrollMax = 0,
		mobile = false, edge = 1, autoStep = 1, dragSlop = 1, swipeSlop = 1, holdSlop = 1 }
	-- The list's scroll is answered by one handler for as long as the panel is open: a handler
	-- remade on every frame is a closure a frame, and the range it reports is read from the state
	-- the frame that drew the list left.
	state.scrollHandler = function(by, to)
		return { type = "scroll", key = "queue", max = state.scrollMax, by = by, to = to }
	end
	return state
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
	elseif message.type == "hoverQueue" then
		if overlay.state.hover ~= message.index then
			overlay.state.hover = message.index
			app:refresh()
		end
		return true
	elseif message.type == "queueGesture" then
		-- A row is moving: what the gesture came to is the state the next frame is built from.
		app:refresh()
		return true
	elseif message.type == "queueRemove" or message.type == "queueMove" then
		-- Editing the queue leaves the panel open, so the message is taken here and handed on
		-- rather than passing over a light overlay and closing it. A removal is the heavier
		-- answer, as it is everywhere else in the app; a move is a lighter confirmation.
		-- The rows are about to be other rows, so no gesture or hover of the old ones survives.
		overlay.state.hover, overlay.state.press, overlay.state.drag, overlay.state.swipe = nil, nil, nil, nil
		local haptics = app.services.haptics
		if haptics ~= nil then
			if message.type == "queueRemove" then haptics:heavy() else haptics:tick() end
		end
		app:toService(message)
		app:refresh()
		return true
	elseif message.type == "queueChanged" then
		-- The queue behind the panel changed -- an edit landed, or a track started -- and the
		-- panel is about to show it, so it takes the announcement instead of closing on it.
		app:refresh()
		return true
	end
	return false
end

--- The queue is a panel instead of a permanent column, so the cover and controls keep the room
--- on every width. It opens from the queue button, as tall as the queue up to the room on that
--- side of the button, and scrolls past that.
---@param app beat.App
---@param overlay beat.OverlayInstance<beat.QueueState>
---@param window wonderland.RenderWindow
---@return wonderland.Element?
function queuePanel.view(app, overlay, window)
	local state = overlay.state
	local anchor = state.anchor
	if anchor == nil then return nil end
	local toolWidth = anchor.toolWidth
	local room = anchor.room
	local theme = app.services.appearance.theme
	local mobile = metrics.mobile(app, window.width)
	local queue = app.services.playback.player.queue
	-- The panel draws only its visible rows, so it asks the queue for the count and then for the
	-- track at each visible place rather than for the whole rest of the queue every frame.
	local count = queue ~= nil and queue:upcomingCount() or 0
	local rowHeight = theme:px(48)
	local padding = theme:px(10)
	local headerHeight = theme:px(24)
	local gap = theme:px(4)
	local width = math.min(theme:px(340), toolWidth)
	local inner = width - padding * 2
	local fixed = padding * 2 + headerHeight + gap

	local fullHeight = count * rowHeight
	local space = math.max(room.below, room.above) - theme:px(6)
	local listHeight = math.max(rowHeight, math.min(fullHeight, space - fixed))
	local height = fixed + listHeight
	local scrollMax = math.max(0, fullHeight - listHeight)
	local offset = math.min(app.services.scroll:offset("queue"), scrollMax)
	-- The bar takes its strip from the rows, so they are narrowed by it rather than run under it.
	local barWidth = theme:px(6)
	local listWidth = scrollMax > 0 and (inner - barWidth) or inner

	-- What the gestures read, as the frame that draws them leaves it.
	state.count = count
	state.rowHeight = rowHeight
	state.listWidth = listWidth
	state.listHeight = listHeight
	state.scrollMax = scrollMax
	state.scrollOffset = offset
	state.mobile = mobile
	state.edge = theme:px(20)
	state.autoStep = theme:px(12)
	state.dragSlop = theme:px(4)
	state.swipeSlop = theme:px(10)
	state.holdSlop = theme:px(6)
	if state.countLabelCount ~= count then
		state.countLabel = format.count(count, "track")
		state.countLabelCount = count
	end
	if state.hover ~= nil and (state.hover < 1 or state.hover > count) then state.hover = nil end
	if state.press ~= nil and (state.press.index < 1 or state.press.index > count) then state.press = nil end
	if state.swipe ~= nil and (state.swipe.index < 1 or state.swipe.index > count) then state.swipe = nil end
	if state.drag ~= nil then
		local drag = state.drag
		if drag.index < 1 or drag.index > count then
			state.drag = nil
		else
			if drag.to < 1 then drag.to = 1 end
			if drag.to > count then drag.to = count end
		end
	end

	local heading = queueRow.heading(theme)
	local rows = {}
	rows[#rows + 1] = div()
		:style(heading.row)
		:children(
			{
				text("QUEUE"):style(heading.title),
				text(state.countLabel or ""):style(heading.count)
			}
		)
	if count == 0 then
		rows[#rows + 1] = div()
			:style(heading.emptyRow)
			:children({ text("Nothing queued yet"):style(heading.empty) })
	else
		-- Only the rows in view are built, between spacers that keep the list its full height: a
		-- queue can be a whole library.
		local first, last, top = app.services.scroll.slices(count, 1, rowHeight, offset, listHeight)
		local list = {}
		if top > 0 then list[#list + 1] = div():style(sty():w(listWidth):h(top)) end

		local props = state.rowProps
		if props == nil then
			props = {}
			state.rowProps = props
		end
		props.theme = theme
		props.width = listWidth
		props.height = rowHeight
		props.mobile = mobile
		props.hover = state.hover
		props.drag = state.drag
		props.swipe = state.swipe

		local drag = state.drag
		for slot = first, last do
			local at = slotIndex(drag, slot)
			if at == nil then
				list[#list + 1] = queueRow.gap(props)
			else
				props.track = queue:upcomingAt(at)
				props.index = at
				props.removeMessage = removeFor(at)
				list[#list + 1] = queueRow.view(props)
			end
		end
		if drag ~= nil then
			-- The lifted row itself, over the gap and under the hand: it is out of the stack, so
			-- its place is written as a content offset rather than a slot.
			props.track = queue:upcomingAt(drag.index)
			props.index = drag.index
			props.drag = drag
			list[#list + 1] = queueRow.view(props)
		end
		local bottom = fullHeight - top - (last - first + 1) * rowHeight
		if bottom > 0 then list[#list + 1] = div():style(sty():w(listWidth):h(bottom)) end

		local input = inputFor(app, overlay)
		rows[#rows + 1] = div()
			:style(sty():column():w(inner):h(listHeight):bar(barWidth, theme:px(32), theme:color("faint"))):scroll(offset)
			:onMouseDown(input.press):onMouseMove(input.move):onMouseUp(input.release)
			:onScroll(state.scrollHandler):children(list)
	end

	local panel = div()
		:style(
			sty()
				:w(width):h(height):column():pad(padding):gap(gap):radius(theme:radius("md")):bg(theme:color("elevated"))
				:border(theme:px(1), theme:color("border")):shadow(0, theme:px(12), theme:px(30), "#00000099")
		):onClick({ type = "keep" }):children(rows)

	return nowPlaying.toolPanel(app, panel, 0, width, height, room, "queuePanel")
end

return queuePanel
