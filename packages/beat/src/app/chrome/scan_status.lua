-- The scan's two cards over the top right corner: the island while the worker is reading, and
-- the summary that replaces it once the scan is done.
local wonderland = require("wonderland")
local path = require("path")
local ui = require("beat-ui")
local core = require("beat-core")
local render = require("beat.app.ui")
local metrics = require("beat.app.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty
local util = core.util

local scanStatus = {}

--- The compact scan card: a floating island while the worker is reading, with the same progress
--- the sidebar footer keeps after it is collapsed. It only appears once there is a track to browse.
---@param app beat.App
---@param width number
---@return wonderland.Element?
function scanStatus.island(app, width)
	local library = app.services.library
	local scan = app.services.scan
	if scan.job == nil or not scan.islandOpen or library.current == nil
	or #library.current.tracks == 0 then
		return nil
	end

	local theme = app.services.appearance.theme
	local progress = scan.job:progress()
	local fraction = render.scanFraction(progress)
	local islandWidth = math.min(theme:px(340), width - metrics.pad(app, width) * 2)
	local islandHeight = theme:px(112)
	local pad = theme:px(14)
	local barHeight = theme:px(4)
	local radius = theme:radius("md")
	local margin = metrics.mobile(app, width) and metrics.pad(app, width) or theme:space(24)
	local current = nil
	if type(progress.current) == "string" then current = path.basename(progress.current) end
	local label = progress.phase == "enumerate" and "Finding music" or "Reading metadata"

	return div()
	:style(sty():w(islandWidth):h(islandHeight):offset(width - islandWidth - margin,
	metrics.topbarHeight(app, width) + theme:space(8))
	:z(60):column():pad(pad, pad, 0, pad):gap(theme:px(8))
	:radius(radius):bg(theme:color("elevated"))
	:shadow(0, theme:px(12), theme:px(32), "#00000070"))
	:canvas(function(canvas)
		render.bottomBar(canvas, {
		x = -pad,
		y = islandHeight - pad - barHeight,
		width = islandWidth,
		height = barHeight,
		radius = radius,
		fraction = fraction,
		trackColour = theme:color("text", 0.1),
		fillColour = theme:color("accent"),
		})
	end)
	:children({
	div():style(sty():row():wrel(1.0):h(theme:px(22)):align("center"):justify("space-between")):children({
	div():style(sty():row():h(theme:px(22)):gap(theme:px(8)):align("center")):children({
	render.equalizer(app, true),
	text("Scanning music"):style(theme:s():text(theme:type("sm")):weight("semibold")
	:fg(theme:color("text"))),
	}),
	render.iconButton(app, "chevronUp", theme:px(22), { type = "hideScanIsland"}),
	}),
	div():style(sty():row():wrel(1.0):h(theme:px(16)):align("center")
	:justify("space-between")):children({
	text(label .. " · " .. progress.inspected .. " / " .. progress.files):style(
	theme:s():text(theme:type("xs")):fg(theme:color("muted"))
	),
	render.button(app, "Cancel", { type = "cancelScan"},
	{ height = theme:px(26), width = theme:px(66)}),
	}),
	current ~= nil and text(tostring(current)):style(theme:s():wrel(1.0):text(theme:type("xs"))
	:fg(theme:color("faint")):ellipsis()) or text(""):style(sty():h(theme:px(0))),
	})
end

--- The card that replaces the scanning island once the scan is done: same place, size and
--- surface, with a check and what the scan added. It is dismissed by a click or after five seconds.
---@param app beat.App
---@param width number
---@return wonderland.Element?
function scanStatus.summary(app, width)
	local summary = app.services.scan.summary
	if summary == nil then return nil end

	local theme = app.services.appearance.theme
	local islandWidth = math.min(theme:px(340), width - metrics.pad(app, width) * 2)
	local islandHeight = theme:px(112)
	local pad = theme:px(14)
	local barHeight = theme:px(4)
	local radius = theme:radius("md")
	local margin = metrics.mobile(app, width) and metrics.pad(app, width) or theme:space(24)

	local detail = summary.skipped > 0
	and util.count(summary.skipped, "file") .. " skipped"
	or "Saved to your library"
	local detailColour = summary.skipped > 0 and theme:color("danger") or theme:color("muted")

	return div()
	:style(sty():w(islandWidth):h(islandHeight):offset(width - islandWidth - margin,
	metrics.topbarHeight(app, width) + theme:space(8))
	:z(60):column():pad(pad, pad, 0, pad):gap(theme:px(8))
	:radius(radius):bg(theme:color("elevated"))
	:shadow(0, theme:px(12), theme:px(32), "#00000070"))
	:onClick({ type = "dismissScanSummary"})
	:canvas(function(canvas)
		render.bottomBar(canvas, {
		x = -pad,
		y = islandHeight - pad - barHeight,
		width = islandWidth,
		height = barHeight,
		radius = radius,
		fraction = 1,
		trackColour = theme:color("text", 0.1),
		fillColour = theme:color("accent"),
		})
	end)
	:children({
	div():style(sty():row():h(theme:px(22)):gap(theme:px(8)):align("center")):children({
	ui.icons.element("check", theme:px(18), theme:color("accent")),
	text("Scan complete"):style(theme:s():text(theme:type("sm")):weight("semibold")
	:fg(theme:color("text"))),
	}),
	text(util.count(summary.tracks, "track") .. " · " .. util.count(summary.albums, "album")):style(
	theme:s():text(theme:type("base")):weight("semibold"):fg(theme:color("text"))
	),
	text(detail):style(theme:s():text(theme:type("xs")):fg(detailColour)),
	})
end

return scanStatus
