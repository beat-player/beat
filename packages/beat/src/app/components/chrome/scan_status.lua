-- The scan's two cards over the top right corner: the island while the worker is reading, and
-- the summary that replaces it once the scan is done.
local wonderland = require("wonderland")
local path = require("path")
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

	return div():style(sty():w(islandWidth):h(islandHeight):offset(width - islandWidth - margin, metrics.topbarHeight(app, width) + theme:space(8)):z(60):column():pad(pad, pad, 0, pad):gap(theme:px(8)):radius(radius):bg(theme:color("elevated")):shadow(0, theme:px(12), theme:px(32), "#00000070")):canvas(function(canvas)
		bottomBar(canvas, { x = -pad, y = islandHeight - pad - barHeight, width = islandWidth, height = barHeight, radius = radius, fraction = fraction, trackColour = theme:color("text", 0.1), fillColour = theme:color("accent") })
	end):children({ div():style(sty():row():wrel(1.0):h(theme:px(22)):align("center"):justify("space-between")):children({ div():style(sty():row():h(theme:px(22)):gap(theme:px(8)):align("center")):children({ playingBars.view(app, { playing = true }), text("Scanning music"):style(theme:s():text(theme:type("sm")):weight("semibold"):fg(theme:color("text"))) }), ui.iconButton(ctx, { name = "chevronUp", size = theme:px(22), onClick = { type = "hideScanIsland" } }) }), div():style(sty():row():wrel(1.0):h(theme:px(16)):align("center"):justify("space-between")):children({ text(label .. " · " .. progress.inspected .. " / " .. progress.files):style(theme:s():text(theme:type("xs")):fg(theme:color("muted"))), ui.button(ctx, { label = "Cancel", onClick = { type = "cancelScan" }, height = theme:px(26), width = theme:px(66) }) }), current ~= nil and text(tostring(current)):style(theme:s():wrel(1.0):text(theme:type("xs")):fg(theme:color("faint")):ellipsis()) or text(""):style(sty():h(theme:px(0))) })
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

	local detail = summary.skipped > 0 and format.count(summary.skipped, "file") .. " skipped" or "Saved to your library"
	local detailColour = summary.skipped > 0 ? (theme:color("danger")) : (theme:color("muted"))

	return div():style(sty():w(islandWidth):h(islandHeight):offset(width - islandWidth - margin, metrics.topbarHeight(app, width) + theme:space(8)):z(60):column():pad(pad, pad, 0, pad):gap(theme:px(8)):radius(radius):bg(theme:color("elevated")):shadow(0, theme:px(12), theme:px(32), "#00000070")):onClick({ type = "dismissScanSummary" }):canvas(function(canvas)
		bottomBar(canvas, { x = -pad, y = islandHeight - pad - barHeight, width = islandWidth, height = barHeight, radius = radius, fraction = 1, trackColour = theme:color("text", 0.1), fillColour = theme:color("accent") })
	end):children({ div():style(sty():row():h(theme:px(22)):gap(theme:px(8)):align("center")):children({ ui.icon(ctx, { name = "check", size = theme:px(18), colour = theme:color("accent") }), text("Scan complete"):style(theme:s():text(theme:type("sm")):weight("semibold"):fg(theme:color("text"))) }), text(format.count(summary.tracks, "track") .. " · " .. format.count(summary.albums, "album")):style(theme:s():text(theme:type("base")):weight("semibold"):fg(theme:color("text"))), text(detail):style(theme:s():text(theme:type("xs")):fg(detailColour)) })
end

return scanStatus
