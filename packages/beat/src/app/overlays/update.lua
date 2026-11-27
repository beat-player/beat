-- The update a check found: what it is, what is installed, and the two ways out of the dialog.
-- The service owns the download and the restart; this only says what they are doing. A phone
-- closes the dialog once its browser has the APK, because the system's installer takes it from
-- there; a desktop stays open to show the download and then asks for the restart that swaps the
-- executable.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local platform = require("beat.platform")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.UpdateOverlayState: beat.OverlayState

---@class beat.UpdateOverlay: beat.OverlaySurface
local update = {}

---@param app beat.App
---@param _params table
---@return beat.UpdateOverlayState
function update.new(app, _params)
	return {}
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.UpdateOverlayState>
---@param message beat.Message
function update.update(app, overlay, message)
	-- On a phone the download belongs to the browser and the dialog has done its work. Closing it
	-- here and letting the message through means the service still opens the link without a second
	-- message kind or a dialog left over the settings page.
	if message.type == "applyUpdate" and platform.android then
		app:close("update")
	end
	return false
end

-- What the transfer is doing, as the line above the bar says it. The percent only changes when a
-- whole percent arrives, so the line is rebuilt then rather than on every frame the dialog is open.
local DOWNLOADING = "Downloading…"
local downloadTextCache = { percent = nil, text = DOWNLOADING }

---@param progress number?
---@return string
local function downloadText(progress)
	if progress == nil then return DOWNLOADING end
	local percent = math.floor(progress * 100)
	if percent ~= downloadTextCache.percent then
		downloadTextCache.percent = percent
		downloadTextCache.text = DOWNLOADING .. " " .. percent .. "%"
	end
	return downloadTextCache.text
end

-- The offer's line, and the installed version in the otherwise idle dialog: the same string for
-- the same offer or version, rather than a concatenation per frame.
---@type table<beat.UpdateOffer, string>
local offerLines = setmetatable({}, { __mode = "k" })

---@param offer beat.UpdateOffer?
---@return string
local function offerLine(offer)
	if offer == nil then return "An update is ready to install." end
	local line = offerLines[offer]
	if line == nil then
		line = offer.label .. " is ready to install."
		offerLines[offer] = line
	end
	return line
end

---@type table<string, string>
local installedLines = {}

---@param version string
---@return string
local function installedLine(version)
	local line = installedLines[version]
	if line == nil then
		line = "You have " .. version
		installedLines[version] = line
	end
	return line
end

--- What the dialog's bar shows for the service as it is: the fraction the transfer last
--- reported, the bytes behind it when the server gave a length, and whether there is a length at
--- all. No length is what libcurl reports until the response headers arrive, and it is the bar's
--- one reason to slide rather than fill.
---@class beat.UpdateBarState
---@field fraction number?
---@field received number?
---@field total number?
---@field indeterminate boolean

---@class beat.UpdateBarSource
---@field status string?
---@field progress number?
---@field progressReceived number?
---@field progressTotal number?

---@param service beat.UpdateBarSource
---@return beat.UpdateBarState
function update.barState(service)
	local total = service.progressTotal
	return {
		fraction = service.progress,
		received = service.progressReceived,
		total = total,
		indeterminate = service.status == "downloading" and total == nil
	}
end

local MEGABYTE = 1024 * 1024

--- The transfer in bytes, as the muted line under the bar writes it, or nothing when the server
--- did not say how large the file is.
---@param received number?
---@param total number?
---@return string?
local bytesTextCache = { received = nil, total = nil, text = nil }

function update.bytesText(received, total)
	if type(received) ~= "number" or type(total) ~= "number" or total <= 0 then return nil end
	if received ~= bytesTextCache.received or total ~= bytesTextCache.total then
		bytesTextCache.received = received
		bytesTextCache.total = total
		bytesTextCache.text = string.format("%.1f of %.1f MB", received / MEGABYTE, total / MEGABYTE)
	end
	return bytesTextCache.text
end

--- How many whole pixels the fill covers: a bar this wide at this fraction. The fill is snapped
--- to a pixel so a redraw of the same fraction draws the same rectangle, and a canvas is not asked
--- to antialias a width that will be cut off anyway.
---@param fraction number?
---@param width number
---@return number
function update.fillWidth(fraction, width)
	if type(fraction) ~= "number" or fraction ~= fraction then return 0 end
	local clamped = math.max(0, math.min(1, fraction))
	return math.floor(width * clamped)
end

---@class beat.UpdateBarDraw
---@field width number
---@field height number
---@field fraction number?
---@field indeterminate boolean
---@field track string
---@field fill string
---@field style wonderland.StyleBuilder
---@field draw fun(canvas: wonderland.Canvas)

--- The draw of one bar, made when the record is made rather than by every frame: a function
--- declared in the view is a closure the trace compiler closes each time, which leaves the frame
--- interpreted. The record's numbers are read here when the frame is painted.
---@param state beat.UpdateBarDraw
---@return fun(canvas: wonderland.Canvas)
local function drawFor(state)
	return function(canvas)
		local height = canvas.height
		local radius = height / 2
		canvas:rect(0, 0, canvas.width, height, state.track, radius)
		if state.indeterminate then
			-- A band a little under a third of the track, sliding across and off it once every
			-- one and two-third seconds. Time is read here so a frame the app asks for moves it
			-- without the view being built again.
			local band = canvas.width * 0.3
			local span = canvas.width + band
			local start = (wonderland.time.now() * 0.6) % 1 * span - band
			local left = math.max(0, start)
			local right = math.min(canvas.width, start + band)
			if right > left then canvas:rect(left, 0, right - left, height, state.fill, radius) end
		else
			local filled = update.fillWidth(state.fraction, canvas.width)
			if filled > 0 then canvas:rect(0, 0, filled, height, state.fill, radius) end
		end
	end
end

--- The bar: a track in the theme's border colour, an accent fill over it, and the same rounded
--- ends for both. Its style and draw are kept for the one width the dialog has, on the theme that
--- made them: a progress change updates the record's fraction rather than making a draw per frame.
---@param theme beat.Theme
---@param width number
---@param height number
---@param fraction number?
---@param indeterminate boolean
---@return wonderland.Element
local function barView(theme, width, height, fraction, indeterminate)
	local cache = theme:cache()
	local record = cache.updateBar --[[@as beat.UpdateBarDraw?]]
	if record == nil or record.width ~= width or record.height ~= height then
		record = {
			width = width,
			height = height,
			fraction = fraction,
			indeterminate = indeterminate,
			track = theme:color("border"),
			fill = theme:color("accent"),
			style = sty():w(width):h(height):radius(theme:radius("full")),
			draw = nil --[[@as fun(canvas: wonderland.Canvas)]]
		}
		record.draw = drawFor(record)
		cache.updateBar = record
	end
	record.fraction = fraction
	record.indeterminate = indeterminate
	return div():style(record.style):clip():canvas(record.draw)
end

--- The dialog's text and action row: the same for every frame of every status, on this theme.
---@class beat.UpdateStyles
---@field title wonderland.StyleBuilder
---@field offer wonderland.StyleBuilder
---@field detail wonderland.StyleBuilder
---@field bytes wonderland.StyleBuilder
---@field actions wonderland.StyleBuilder
---@field overlay wonderland.StyleBuilder

---@param theme beat.Theme
---@return beat.UpdateStyles
local function updateStyles(theme)
	local cache = theme:cache()
	local record = cache.updateStyles --[[@as beat.UpdateStyles?]]
	if record ~= nil then return record end
	local lineHeight = theme:px(18)
	record = {
		title = theme:s():wrel(1.0):h(theme:px(26)):text(theme:type("lg")):weight("bold"):fg(theme:color("text")),
		offer = theme:s():wrel(1.0):h(lineHeight):text(theme:type("sm")):fg(theme:color("muted")):ellipsis(),
		detail = theme:s():wrel(1.0):h(lineHeight):text(theme:type("sm")):fg(theme:color("muted")):ellipsis(),
		bytes = theme:s():wrel(1.0):h(theme:px(14)):text(theme:type("xs")):fg(theme:color("muted")):ellipsis(),
		actions = sty():row():wrel(1.0):h(theme:px(38)):gap(theme:px(8)):align("center"):justify("end"),
		overlay = sty():fill():offset(0, 0):z(120):column():align("center"):justify("center"):bg(theme:color("overlay"))
	}
	cache.updateStyles = record
	return record
end

--- The panel at the size its content came to, kept on the theme until that size changes.
---@param theme beat.Theme
---@param width number
---@param height number
---@param pad number
---@param gap number
---@return wonderland.StyleBuilder
local function panelStyle(theme, width, height, pad, gap)
	local cache = theme:cache()
	local kept = cache.updatePanel
	if kept ~= nil and kept.width == width and kept.height == height then return kept.style end
	local style = sty()
		:w(width):h(height):column():pad(pad):gap(gap):radius(theme:radius("lg"))
		:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
		:shadow(0, theme:px(16), theme:px(42), "#00000080")
	cache.updatePanel = { width = width, height = height, style = style }
	return style
end

---@param app beat.App
---@param _overlay beat.OverlayInstance<beat.UpdateOverlayState>
---@param window wonderland.RenderWindow
function update.view(app, _overlay, window)
	local service = app.services.update
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local panelWidth = ctx:panelWidth(380)
	local pad = theme:px(20)
	local gap = theme:px(14)
	local titleHeight = theme:px(26)
	local lineHeight = theme:px(18)
	local buttonHeight = theme:px(38)
	local barHeight = theme:px(6)
	local bytesHeight = theme:px(14)
	local status = service.status
	local offer = service.offer
	local styles = updateStyles(theme)

	local detail
	local actions
	local bar
	local barBytes
	if status == "downloading" then
		-- The service's own numbers are read here rather than poured into a fresh record: the bar
		-- and the two lines keep their own values and change only when a percent or a byte arrives.
		local fraction = service.progress
		local total = service.progressTotal
		detail = downloadText(fraction)
		bar = barView(theme, panelWidth - pad * 2, barHeight, fraction, total == nil)
		barBytes = update.bytesText(service.progressReceived, total)
	elseif status == "ready" then
		detail = "Restart beat to finish"
		actions = div()
			:style(styles.actions)
			:children({
				ui.button(
					ctx,
					{
						label = "Restart",
						onClick = { type = "relaunchUpdate" },
						variant = "primary",
						height = theme:px(36),
						width = theme:px(96)
					}
				)
			})
	else
		detail = installedLine(service.installedVersion)
		actions = div()
			:style(styles.actions)
			:children({
				ui.button(
					ctx,
					{ label = "Later", onClick = { type = "dismiss" }, variant = "quiet", height = theme:px(36), width = theme:px(84) }
				),
				ui.button(
					ctx,
					{ label = "Update", onClick = { type = "applyUpdate" }, variant = "primary", height = theme:px(36), width = theme:px(96) }
				)
			})
	end

	local children = {
		text("Update available"):style(styles.title),
		text(offerLine(offer)):style(styles.offer),
		text(detail):style(styles.detail)
	}
	local contentHeight = titleHeight + lineHeight * 2
	if bar ~= nil then
		children[#children + 1] = bar
		contentHeight = contentHeight + barHeight
	end
	if barBytes ~= nil then
		local bytesLabel = barBytes --[[@as string]]
		children[#children + 1] = text(bytesLabel):style(styles.bytes)
		contentHeight = contentHeight + bytesHeight
	end
	if actions ~= nil then
		children[#children + 1] = actions
		contentHeight = contentHeight + buttonHeight
	end

	local gaps = #children - 1
	local panelHeight = pad * 2 + contentHeight + gap * gaps
	local panel = div()
		:style(panelStyle(theme, panelWidth, panelHeight, pad, gap))
		:onClick({ type = "keep" })
		:children(children)

	return div():style(styles.overlay):children({ panel })
end

return update
