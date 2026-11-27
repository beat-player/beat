-- What a press looks like: a circle that grows from where it landed and fades away, drawn inside
-- the rounded box of the control it was pressed on. A finger gets the full mark and a mouse the
-- same mark at half the ink, so a touch screen and a desk feel like one app without a pointer
-- leaving a bright smear behind it every time it clicks.
--
-- The animation is one record per control, not one per frame: a component calls `attach` while it
-- builds, which teaches the control to tell the ripple about a press and, while a ripple is
-- running, hands it a draw. The circle is drawn in slices of two rows of pixels, each cut to the
-- control's box and its rounded corners, which is what keeps it inside a row that has been pressed
-- at its edge and what keeps a frame's quads in the hundreds rather than the thousands.
--
-- Nothing here ticks. The app's ripple service is what asks `advance`, which frees the ripples that
-- are over and says whether any is still moving; until it does, a press is a slot that is there and
-- a draw that keeps reading the clock. Every slot is made up front: a press allocates nothing.
--
-- With reduced motion on, the circle is replaced by the control's own box lit for a moment and
-- faded: the same press, without anything moving across the screen.
local wonderland = require("wonderland")
local time = wonderland.time

local ripple = {}

-- How long the circle takes to reach the farthest corner of its control, and how long it takes to
-- fade once the press is over. A tap is a full expand and then a fade; a hold stays full until it
-- is let go of, because the fade starts when the press ends.
local EXPAND = 0.32
local FADE = 0.18

-- The reduced-motion highlight: it holds for a moment and then fades out.
local FLAT_HOLD = 0.1
local FLAT_FADE = 0.16

-- How much of the foreground a press lays over what is under it. A finger hides its own mark, so it
-- can be twice as strong as the one a mouse leaves.
local TOUCH_ALPHA = 0.12
local MOUSE_ALPHA = 0.06

-- The most ripples that can be running at once. More than one finger cannot press more than a few
-- controls before the first is over, and a slot reused after its ripple has run out costs nothing.
local SLOT_COUNT = 6

--- Whether the listener asked for less motion. The ripple service keeps this in step with the
--- setting; a screen with no service -- a test, a preview -- shows the full ripple.
---@type boolean
ripple.reduced = false

---@class beat.ui.RippleSlot
---@field free boolean
---@field record beat.ui.RippleRecord?
---@field x number # Where the press landed, in the control's own box
---@field y number
---@field width number # The control's box when it was pressed: a draw of another box is not it
---@field height number
---@field start number
---@field fadeAt number # When the fade begins, and when it ends
---@field endAt number
---@field radius number # How far the farthest corner is from the press, which is as big as it gets
---@field alpha number
---@field flat boolean # Reduced motion: the box lit rather than a circle growing

--- What a control keeps for its press: the mark it draws, its colour, and the slot it is using.
---@class beat.ui.RippleRecord
---@field key any # The control's key: a number of its own when the component gave none
---@field colour string? # What it was last told to draw in
---@field tint number[] # That colour, as the four channels a canvas packs, with alpha written per frame
---@field slot beat.ui.RippleSlot?
---@field press fun(x: number, y: number, width: number, height: number, touch: boolean)
---@field release fun()
---@field draw fun(canvas: wonderland.Canvas)

-- The slots, made once: a press writes into one rather than making a table the frame has to collect.
---@type beat.ui.RippleSlot[]
local slots = {}
for at = 1, SLOT_COUNT do
	slots[at] = {
		free = true,
		record = nil,
		x = 0,
		y = 0,
		width = 0,
		height = 0,
		start = 0,
		fadeAt = 0,
		endAt = 0,
		radius = 0,
		alpha = 0,
		flat = false
	}
end

local activeCount = 0

--- A number that moves every time a mark starts or ends, so a ticker can tell a frame that has to
--- build the screen again -- the frame a mark's draw is attached on, or the one it is taken off --
--- from the frames in between, which only have to draw what the canvas draws.
---@type number
ripple.generation = 0

-- One record per control, kept while the app runs: a component asks for the same key on every
-- frame, and a record made again for each frame would be the closures behind it made again too.
---@type table<any, beat.ui.RippleRecord>
local records = {}

--- The four channels a colour string names, in the table the record keeps. A record is drawn in the
--- colour its component last gave it, so a theme change is a parse of the new colour rather than a
--- string built for every frame of the animation.
---@param record beat.ui.RippleRecord
---@param colour string
local function tint(record, colour)
	if record.colour == colour then return end
	record.colour = colour

	local red, green, blue, alpha = 1, 1, 1, 1
	local hex = colour:match("^#(%x+)$")

	if hex ~= nil then
		local step = #hex <= 3 and 1 or 2
		local function part(index)
			local byte = tonumber(hex:sub(index * step + 1, index * step + step), 16) or 0
			if step == 1 then return byte / 15 end
			return byte / 255
		end

		red, green, blue = part(0), part(1), part(2)
		if #hex == 4 or #hex == 8 then alpha = part(3) end
	end

	local channels = record.tint
	channels[1], channels[2], channels[3], channels[4] = red, green, blue, alpha
end

--- The corners of a control's box, as round as its style said but never rounder than half its
--- shortest side: a pill and a circle are the same rounded box at that limit.
---@param canvas wonderland.Canvas
---@return number
local function cornerRadius(canvas)
	local radius = canvas.boxRadius
	local limit = canvas.boxWidth * 0.5
	local tall = canvas.boxHeight * 0.5
	if tall < limit then limit = tall end
	if radius > limit then radius = limit end
	if radius < 0 then return 0 end
	return radius
end

--- How far a rounded box is cut in on one row: its sides are straight down the middle and bow in
--- towards the corners, which is what a circle drawn in slices has to be cut to as well.
---@param by number # The box's top, in the room's coordinates
---@param height number
---@param radius number
---@param y number
---@return number
local function roundedInset(by, height, radius, y)
	if radius <= 0 then return 0 end

	local from, to = by + radius, by + height - radius
	local away

	if y < from then
		away = from - y
	elseif y > to then
		away = y - to
	else
		return 0
	end

	if away >= radius then return radius end

	local inside = radius * radius - away * away
	if inside < 0 then inside = 0 end
	return radius - math.sqrt(inside)
end

--- Draws the mark of one record's running ripple: a circle grown from where the press landed, or,
--- with reduced motion on, the control's own box lit for a moment. Both are cut to the control's
--- box and its rounded corners.
---@param record beat.ui.RippleRecord
---@param canvas wonderland.Canvas
local function draw(record, canvas)
	local slot = record.slot
	if slot == nil or slot.free then return end

	local now = time.now()
	if now >= slot.endAt then return end

	-- A control that was rebuilt with a different box is not the one that was pressed: the same
	-- place in the screen has been taken by something else, and a mark of its own is not this one.
	local boxWidth, boxHeight = canvas.boxWidth, canvas.boxHeight
	if math.abs(boxWidth - slot.width) > 1 or math.abs(boxHeight - slot.height) > 1 then return end

	local fade
	if now <= slot.fadeAt then
		fade = 1
	else
		fade = 1 - (now - slot.fadeAt) / (slot.flat and FLAT_FADE or FADE)
		if fade <= 0 then return end
	end

	local channels = record.tint
	channels[4] = slot.alpha * fade

	local boxX, boxY = canvas.boxX, canvas.boxY
	if slot.flat then
		canvas:rect(boxX, boxY, boxWidth, boxHeight, channels, cornerRadius(canvas))
		return
	end

	local progress = (now - slot.start) / EXPAND
	if progress >= 1 then
		progress = 1
	elseif progress < 0 then
		progress = 0
	end

	-- Ease out: the mark is most of the way across in the first half of the time it takes to fill.
	local left = 1 - progress
	local radius = slot.radius * (1 - left * left * left)
	if radius <= 0 then return end

	local originX, originY = slot.x + boxX, slot.y + boxY
	local radius2 = radius * radius
	local round = cornerRadius(canvas)
	local alpha = channels[4]
	local topY, bottomY = originY - radius, originY + radius

	-- One slice for each band of two rows the mark reaches, and none outside the box it is drawn in:
	-- the circle is the span of each band, and the box takes what is outside its rounded sides away.
	-- A band the top or the bottom of the circle cuts through is drawn at the share of it the circle
	-- covers, so a circle growing at low opacity does not read as a staircase; the two ends of a band
	-- keep to whole pixels, because at the ink of a press a pixel of edge is not a thing the eye
	-- finds, and a band of two rows is half the quads a row of them costs.
	local BAND = 2
	local first = math.floor(topY - boxY)
	if first < 0 then first = 0 end
	local last = math.ceil(bottomY - boxY)
	if last > boxHeight then last = boxHeight end

	for row = first, last - 1, BAND do
		local band = last - row
		if band > BAND then band = BAND end
		local y = boxY + row
		local middle = y + band * 0.5
		local dy = middle - originY
		local inside = radius2 - dy * dy

		if inside > 0 then
			-- How much of this band the circle crosses: all of it but the first and the last.
			local coverage = band
			if y < topY then coverage = coverage - (topY - y) end
			if y + band > bottomY then coverage = coverage - (y + band - bottomY) end
			if coverage > band then coverage = band end
			if coverage > 0 then coverage = coverage / band end

			local half = math.sqrt(inside)
			local inset = roundedInset(boxY, boxHeight, round, middle)
			local spanLeft, spanRight = boxX + inset, boxX + boxWidth - inset

			if coverage > 0 and spanRight - spanLeft >= 1 then
				local from, to = originX - half, originX + half
				if from < spanLeft then from = spanLeft end
				if to > spanRight then to = spanRight end

				if to > from then
					-- The pixels the span touches, kept inside the rounded box the band is cut to.
					local firstPixel = math.max(math.floor(from), math.ceil(spanLeft))
					local lastPixel = math.min(math.ceil(to) - 1, math.floor(spanRight) - 1)

					if lastPixel >= firstPixel then
						local share = coverage
						-- Thinner than the pixel it is in: a share of that one.
						if to - from < 1 then share = share * (to - from) end

						channels[4] = alpha * share
						canvas:rect(firstPixel, y, lastPixel - firstPixel + 1, band, channels, 0)
					end
				end
			end
		end
	end
end

--- The slot a press belongs in: the one the record already has, a free one, or the one nearest its
--- end, so a press with every slot running still shows something.
---@param record beat.ui.RippleRecord
---@return beat.ui.RippleSlot?
local function takeSlot(record)
	local running = record.slot
	if running ~= nil and not running.free then return running end
	record.slot = nil

	local oldest = nil
	for at = 1, SLOT_COUNT do
		local slot = slots[at]
		if slot.free then
			slot.free = false
			slot.record = record
			record.slot = slot
			activeCount = activeCount + 1
			return slot
		end
		if oldest == nil or slot.endAt < oldest.endAt then oldest = slot end
	end

	if oldest == nil then return nil end

	-- Every slot is running: the one that ends first makes way, and the mark it was drawing stops.
	local replaced = oldest.record
	if replaced ~= nil and replaced.slot == oldest then replaced.slot = nil end
	oldest.record = record
	record.slot = oldest

	return oldest
end

---@param slot beat.ui.RippleSlot
local function free(slot)
	if slot.free then return end

	local record = slot.record
	if record ~= nil and record.slot == slot then record.slot = nil end

	slot.free = true
	slot.record = nil
	if activeCount > 0 then activeCount = activeCount - 1 end
	ripple.generation = ripple.generation + 1
end

--- A press on the control `key` names, at a place in its box. `touch` says a finger made it, which
--- is the stronger mark; `at` is the moment, for a caller stepping the animation itself.
---@param key any
---@param x number
---@param y number
---@param width number
---@param height number
---@param touch boolean
---@param at number? # Default the clock's now
---@return beat.ui.RippleSlot?
function ripple.press(key, x, y, width, height, touch, at)
	local record = records[key]
	if record == nil then
		return nil
	end

	local slot = takeSlot(record)
	if slot == nil then return nil end

	local now = at or time.now()
	local flat = ripple.reduced

	slot.x, slot.y = x, y
	slot.width, slot.height = width, height
	slot.start = now
	slot.alpha = touch and TOUCH_ALPHA or MOUSE_ALPHA
	slot.flat = flat

	-- The farthest corner is what the circle has to reach to cover the whole control.
	local dx = x > width - x and x or width - x
	local dy = y > height - y and y or height - y
	slot.radius = math.sqrt(dx * dx + dy * dy) + 1

	if flat then
		slot.fadeAt = now + FLAT_HOLD
		slot.endAt = slot.fadeAt + FLAT_FADE
	else
		slot.fadeAt = now + EXPAND
		slot.endAt = slot.fadeAt + FADE
	end

	ripple.generation = ripple.generation + 1

	return slot
end

--- The press on `key` is over: the mark fades from where it has got to, and a mark that is still
--- growing finishes growing first, so a tap is one movement rather than a cut.
---@param key any
---@param at number?
function ripple.release(key, at)
	local record = records[key]
	if record == nil then return end

	local slot = record.slot
	if slot == nil or slot.free or slot.flat then return end

	local now = at or time.now()
	if now > slot.fadeAt then
		slot.fadeAt = now
		slot.endAt = now + FADE
	end
end

--- Frees the ripples that are over. Answers how many are still running, and whether any slot was
--- freed -- a frame owes a rebuild when one was, because the draw of the mark that ended goes with
--- the control.
---@param now number
---@return number active
---@return boolean changed
function ripple.advance(now)
	local active, changed = 0, false

	for at = 1, SLOT_COUNT do
		local slot = slots[at]
		if not slot.free then
			if now >= slot.endAt then
				free(slot)
				changed = true
			else
				active = active + 1
			end
		end
	end

	activeCount = active
	return active, changed
end

--- Whether anything is still moving. It is what `advance` last answered, so a caller that never
--- advances hears nothing.
---@return boolean
function ripple.busy()
	return activeCount > 0
end

--- Ends the ripples that belong to where the app was rather than to a control: the ones a component
--- gave no key of its own, which are held by the place they had in the screen. A page or an overlay
--- arriving puts other controls in those places, and a mark that went on there would be drawn on
--- something nobody pressed.
---
--- The records of those controls go with them: a place in the screen is only an identity while the
--- screen is the same one, and what was made for the last page's places is never asked for again.
--- A named control's record is kept, because the name is what says it is still there.
---@return number cleared
function ripple.clearVolatile()
	local cleared = 0

	for at = 1, SLOT_COUNT do
		local slot = slots[at]
		if not slot.free and slot.record ~= nil and type(slot.record.key) == "number" then
			free(slot)
			cleared = cleared + 1
		end
	end

	for key, record in pairs(records) do
		if type(key) == "number" and record.slot == nil then records[key] = nil end
	end

	return cleared
end

--- Ends every ripple, and forgets the controls that were drawing them: what a test does between
--- cases, and what a screen built again wants.
function ripple.reset()
	for at = 1, SLOT_COUNT do free(slots[at]) end
	activeCount = 0
	records = {}
	ripple.reduced = false
	ripple.generation = ripple.generation + 1
end

--- Whether `key` has a ripple running, and where the press that made it landed.
---@param key any
---@return beat.ui.RippleSlot?
function ripple.slot(key)
	local record = records[key]
	if record == nil then return nil end
	return record.slot
end

--- Teaches a control to show a press: a key that is the same on every frame, the colour the mark is
--- drawn in, and the canvas that draws it while there is one. The key may be left out, and then it
--- is the element's place in the screen, which is right for a control that is not part of a list.
---@param element wonderland.Element
---@param key any? # A string for a control that keeps its identity across frames; default its place in the frame
---@param colour string # The mark's colour at full strength; the press's ink is this at a share of its alpha
---@return wonderland.Element
function ripple.attach(element, key, colour)
	if key == nil then key = element.index end

	local record = records[key]
	if record == nil then
		record = {
			key = key,
			colour = nil,
			tint = { 1, 1, 1, 1 },
			slot = nil
		}
		record.press = function(x, y, width, height, touch)
			ripple.press(key, x, y, width, height, touch)
		end
		record.release = function()
			ripple.release(key)
		end
		record.draw = function(canvas)
			draw(record, canvas)
		end
		records[key] = record
	end

	tint(record, colour)
	element:onPress(record.press)
	element:onPressEnd(record.release)

	local slot = record.slot
	if slot ~= nil and slot.endAt <= time.now() then
		free(slot)
		slot = nil
	end
	if slot ~= nil then element:canvas(record.draw) end

	return element
end

return ripple
