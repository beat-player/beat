-- The scan's two cards over the top right corner: the island while the worker is reading, and
-- the summary that replaces it once the scan is done.
local wonderland = require("wonderland")
local path = require("path")
local cache = require("beat-ui.cache")
local ui = require("beat-ui")
local format = require("beat.app.components.helpers.format")
local metrics = require("beat.app.components.helpers.metrics")
local playingBars = require("beat.app.components.playing_bars")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local scanStatus = {}

local BOTTOM_STRIP_SEGMENTS = 8

--- The outline of the bottom `height` pixels of a rounded box, as a convex polygon. The strip
--- follows the box's bottom corners even when the strip is shorter than the corner radius, which
--- is what makes it a border of the box rather than a line floating below it.
---@param width number
---@param height number
---@param radius number
local function bottomStrip(width, height, radius)
	local r = math.min(radius, width / 2)
	if r <= 0 or height <= 0 then
		return { 0, 0, width, 0, width, height, 0, height }
	end

	local points = {}
	if height >= r then
		points[#points + 1] = 0
		points[#points + 1] = 0
		points[#points + 1] = width
		points[#points + 1] = 0
		points[#points + 1] = width
		points[#points + 1] = height - r

		for at = 1, BOTTOM_STRIP_SEGMENTS do
			local angle = at / BOTTOM_STRIP_SEGMENTS * math.pi / 2
			points[#points + 1] = width - r + math.cos(angle) * r
			points[#points + 1] = height - r + math.sin(angle) * r
		end

		points[#points + 1] = r
		points[#points + 1] = height

		for at = 1, BOTTOM_STRIP_SEGMENTS do
			local angle = math.pi / 2 + at / BOTTOM_STRIP_SEGMENTS * math.pi / 2
			points[#points + 1] = r + math.cos(angle) * r
			points[#points + 1] = height - r + math.sin(angle) * r
		end
	else
		local angle = math.asin((r - height) / r)
		local inset = r - math.cos(angle) * r
		points[#points + 1] = inset
		points[#points + 1] = 0
		points[#points + 1] = width - inset
		points[#points + 1] = 0

		for at = 1, BOTTOM_STRIP_SEGMENTS do
			local a = angle + (math.pi / 2 - angle) * at / BOTTOM_STRIP_SEGMENTS
			points[#points + 1] = width - r + math.cos(a) * r
			points[#points + 1] = height - r + math.sin(a) * r
		end

		points[#points + 1] = r
		points[#points + 1] = height

		for at = 1, BOTTOM_STRIP_SEGMENTS do
			local a = math.pi / 2 - (math.pi / 2 - angle) * at / BOTTOM_STRIP_SEGMENTS
			points[#points + 1] = r - math.cos(a) * r
			points[#points + 1] = height - r + math.sin(a) * r
		end
	end

	return points
end

--- Cut a convex polygon to the part with x <= `maxX`.
---@param points number[]
---@param maxX number
---@return number[]
local function clipAtX(points, maxX)
	local clipped = {}
	local count = math.floor(#points / 2)

	for at = 1, count do
		local x1, y1 = points[at * 2 - 1], points[at * 2]
		local nextAt = (at % count) + 1
		local x2, y2 = points[nextAt * 2 - 1], points[nextAt * 2]
		local inside1, inside2 = x1 <= maxX, x2 <= maxX

		if inside1 then
			clipped[#clipped + 1] = x1
			clipped[#clipped + 1] = y1
		end

		if inside1 ~= inside2 and x2 ~= x1 then
			local t = (maxX - x1) / (x2 - x1)
			clipped[#clipped + 1] = maxX
			clipped[#clipped + 1] = y1 + (y2 - y1) * t
		end
	end

	return clipped
end

--- A progress strip that is the bottom border of a rounded popup. The track spans the popup's
--- full width and its bottom corners follow the popup's radius; the fill is the same shape cut at
--- the progress width, so it never reads as a separate floating bar.
---@class beat.components.chrome.BottomBarProps
---@field x number
---@field y number
---@field width number
---@field height number
---@field radius number
---@field fraction number
---@field trackColour string
---@field fillColour string

---@param canvas wonderland.Canvas
---@param opts beat.components.chrome.BottomBarProps
local function bottomBar(canvas, opts)
	if opts.width <= 0 or opts.height <= 0 then return end

	local points = bottomStrip(opts.width, opts.height, opts.radius)
	for at = 1, #points, 2 do
		points[at] += opts.x
		points[at + 1] += opts.y
	end

	canvas:polygon(points, opts.trackColour)

	local value = math.max(0, math.min(1, opts.fraction))
	if value <= 0 then return end
	if value >= 1 then
		canvas:polygon(points, opts.fillColour)
		return
	end

	local clipped = clipAtX(points, opts.x + opts.width * value)
	if #clipped >= 6 then canvas:polygon(clipped, opts.fillColour) end
end

-- The card's canvas draws the progress its last frame was told, so the draw is made once per app
-- and per card rather than captured anew: what the canvas reads is the state below, not a closure
-- of the numbers of the frame that built it.
---@class beat.components.chrome.ScanDrawing
---@field draw fun(canvas: wonderland.Canvas)
---@field opts beat.components.chrome.BottomBarProps?

---@type table<beat.App, table<string, beat.components.chrome.ScanDrawing>>
local drawings = setmetatable({}, { __mode = "k" })

--- One card's draw, reading the progress the latest frame left in it.
---@return beat.components.chrome.ScanDrawing
local function newDrawing()
	---@type beat.components.chrome.ScanDrawing
	local entry
	---@param canvas wonderland.Canvas
	local function draw(canvas)
		local opts = entry.opts
		if opts ~= nil then bottomBar(canvas, opts) end
	end
	entry = { draw = draw, opts = nil }
	return entry
end

---@param app beat.App
---@param which string
---@return beat.components.chrome.ScanDrawing
local function drawingOf(app, which)
	local set = drawings[app]
	if set == nil then
		set = {}
		drawings[app] = set
	end
	local entry = set[which]
	if entry == nil then
		entry = newDrawing()
		set[which] = entry
	end
	return entry
end

---@class beat.components.chrome.IslandStyles
---@field head wonderland.StyleBuilder
---@field titleRow wonderland.StyleBuilder
---@field title wonderland.StyleBuilder
---@field detailRow wonderland.StyleBuilder
---@field detail wonderland.StyleBuilder
---@field current wonderland.StyleBuilder
---@field empty wonderland.StyleBuilder

---@param ctx beat.ui.Context
---@return beat.components.chrome.IslandStyles
local function islandStyles(ctx)
	return {
		head = sty():row():wrel(1.0):h(ctx:px(22)):align("center"):justify("space-between"),
		titleRow = sty():row():h(ctx:px(22)):gap(ctx:px(8)):align("center"),
		title = ctx:s():text(ctx:type("sm")):weight("semibold"):fg(ctx:color("text")),
		detailRow = sty():row():wrel(1.0):h(ctx:px(16)):align("center"):justify("space-between"),
		detail = ctx:s():text(ctx:type("xs")):fg(ctx:color("muted")),
		current = ctx:s():wrel(1.0):text(ctx:type("xs")):fg(ctx:color("faint")):ellipsis(),
		empty = sty():h(ctx:px(0))
	}
end

---@class beat.components.chrome.SummaryStyles
---@field row wonderland.StyleBuilder
---@field title wonderland.StyleBuilder
---@field counts wonderland.StyleBuilder
---@field danger wonderland.StyleBuilder
---@field muted wonderland.StyleBuilder

---@param ctx beat.ui.Context
---@return beat.components.chrome.SummaryStyles
local function summaryStyles(ctx)
	return {
		row = sty():row():h(ctx:px(22)):gap(ctx:px(8)):align("center"),
		title = ctx:s():text(ctx:type("sm")):weight("semibold"):fg(ctx:color("text")),
		counts = ctx:s():text(ctx:type("base")):weight("semibold"):fg(ctx:color("text")),
		danger = ctx:s():text(ctx:type("xs")):fg(ctx:color("danger")),
		muted = ctx:s():text(ctx:type("xs")):fg(ctx:color("muted"))
	}
end

---@param ctx beat.ui.Context
---@param islandWidth number
---@param islandHeight number
---@param pad number
---@param radius number
---@param offsetX number
---@param offsetY number
---@return wonderland.StyleBuilder
local function cardBoxStyle(ctx, islandWidth, islandHeight, pad, radius, offsetX, offsetY)
	return sty()
		:w(islandWidth):h(islandHeight):offset(offsetX, offsetY):z(60):column():pad(pad, pad, 0, pad):gap(ctx:px(8))
		:radius(radius):bg(ctx:color("elevated")):shadow(0, ctx:px(12), ctx:px(32), "#00000070")
end

---@class beat.components.chrome.ScanStatusProps
---@field width number # The window's width, which the card is placed against
---@field ui beat.ui.Context

--- The compact scan card: a floating island while the worker is reading, with the same progress
--- the sidebar footer keeps after it is collapsed. It only appears once there is a track to browse.
---@param app beat.App
---@param props beat.components.chrome.ScanStatusProps
---@return wonderland.Element?
function scanStatus.island(app, props)
	local width = props.width
	local ctx = props.ui
	local library = app.services.library
	local scan = app.services.scan
	if scan.job == nil or not scan.islandOpen or library.current == nil or #library.current.tracks == 0 then
		return nil
	end

	local theme = app.services.appearance.theme
	local progress = scan.job:progress()
	local fraction = scan:fraction()
	local islandWidth = math.min(theme:px(340), width - metrics.pad(app, width) * 2)
	local islandHeight = theme:px(112)
	local pad = theme:px(14)
	local barHeight = theme:px(4)
	local radius = theme:radius("md")
	local margin = metrics.mobile(app, width) ? metrics.pad(app, width) : (theme:space(24))
	local current = nil
	if type(progress.current) == "string" then current = path.basename(progress.current) end
	local label = progress.phase == "enumerate" ? "Finding music" : "Reading metadata"

	-- One island, one width: the card's own box and rows are values of the theme and the window,
	-- and only the progress it draws and the text under it change.
	local card = cache.of(ctx, islandStyles, "scanIsland") --[[@as beat.components.chrome.IslandStyles]]

	-- Where the card floats is the window's width against the card's, so its box is made once for
	-- each place it is put: a kept builder is never moved afterwards.
	local offsetX = width - islandWidth - margin
	local offsetY = metrics.topbarHeight(app, width) + theme:space(8)
	local box = cache.of(ctx, cardBoxStyle, "scanIslandOffset", islandWidth, islandHeight, pad, radius, offsetX, offsetY) --[[@as wonderland.StyleBuilder]]

	local drawing = drawingOf(app, "island")
	drawing.opts = {
		x = -pad,
		y = islandHeight - pad - barHeight,
		width = islandWidth,
		height = barHeight,
		radius = radius,
		fraction = fraction,
		trackColour = theme:color("text", 0.1),
		fillColour = theme:color("accent")
	}

	return div():style(box):canvas(drawing.draw):children({
		div():style(card.head):children({
			div():style(card.titleRow):children({
				playingBars.view(app, { playing = true }),
				text("Scanning music"):style(card.title)
			}),
			ui.iconButton(ctx, { name = "chevronUp", size = theme:px(22), onClick = { type = "hideScanIsland" } })
		}),
		div():style(card.detailRow):children({
			text(label .. " · " .. progress.inspected .. " / " .. progress.files):style(card.detail),
			ui.button(ctx, { label = "Cancel", onClick = { type = "cancelScan" }, height = theme:px(26), width = theme:px(66) })
		}),
		current ~= nil and text(tostring(current)):style(card.current) or text(""):style(card.empty)
	})
end

--- The card that replaces the scanning island once the scan is done: same place, size and
--- surface, with a check and what the scan added. It is dismissed by a click or after five seconds.
---@param app beat.App
---@param props beat.components.chrome.ScanStatusProps
---@return wonderland.Element?
function scanStatus.summary(app, props)
	local width = props.width
	local ctx = props.ui
	local summary = app.services.scan.summary
	if summary == nil then return nil end

	local theme = app.services.appearance.theme
	local islandWidth = math.min(theme:px(340), width - metrics.pad(app, width) * 2)
	local islandHeight = theme:px(112)
	local pad = theme:px(14)
	local barHeight = theme:px(4)
	local radius = theme:radius("md")
	local margin = metrics.mobile(app, width) ? metrics.pad(app, width) : (theme:space(24))

	local skipped = summary.skipped > 0
	local detail = skipped and format.count(summary.skipped, "file") .. " skipped" or "Saved to your library"

	local card = cache.of(ctx, summaryStyles, "scanSummary") --[[@as beat.components.chrome.SummaryStyles]]
	local offsetX = width - islandWidth - margin
	local offsetY = metrics.topbarHeight(app, width) + theme:space(8)
	local box = cache.of(ctx, cardBoxStyle, "scanSummaryOffset", islandWidth, islandHeight, pad, radius, offsetX, offsetY) --[[@as wonderland.StyleBuilder]]

	local drawing = drawingOf(app, "summary")
	drawing.opts = {
		x = -pad,
		y = islandHeight - pad - barHeight,
		width = islandWidth,
		height = barHeight,
		radius = radius,
		fraction = 1,
		trackColour = theme:color("text", 0.1),
		fillColour = theme:color("accent")
	}

	return div():style(box):onClick({ type = "dismissScanSummary" }):canvas(drawing.draw):children({
		div():style(card.row):children({
			ui.icon(ctx, { name = "check", size = theme:px(18), colour = theme:color("accent") }),
			text("Scan complete"):style(card.title)
		}),
		text(format.count(summary.tracks, "track") .. " · " .. format.count(summary.albums, "album")):style(card.counts),
		text(detail):style(skipped and card.danger or card.muted)
	})
end

return scanStatus
