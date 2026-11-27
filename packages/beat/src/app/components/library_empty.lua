-- What the library shows when it has nothing to draw: a card in the middle of the page, the way the
-- first launch's welcome is a card. It says the library is empty, names the folder a scan looked in,
-- offers the two ways to change that, and says which files beat can read. A scan that is still
-- running is the same card with its progress, so the first read of a folder is the page rather than
-- a page with its chrome taken away.
local wonderland = require("wonderland")
local path = require("path")
local ui = require("beat-ui")
local cache = require("beat-ui.cache")
local measure = require("beat-ui.measure")
local format = require("beat.app.components.helpers.format")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local libraryEmpty = {}

local TITLE = "Your library is empty"
local CHOOSE_COPY = "Choose a folder to start your library."
local ROOT_COPY = "Nothing playable found in this folder yet."
local FORMATS = "Supported: FLAC · MP3 · Opus · OGG · WAV · M4A"

-- The two actions of the empty card and the one the scan offers. A click on any of them only sends
-- one of these; nothing here reads the app, so one table serves every frame.
local CHOOSE_FOLDER = { type = "chooseFolder" }
local RESCAN = { type = "rescan" }
local CANCEL_SCAN = { type = "cancelScan" }

-- The scan bar's fill: a shape rather than a style, drawn from the last frame's numbers, so the
-- draw is made once instead of closing over a new table on every frame of a scan.
local meterState = { value = 0, track = "", fill = "", radius = 0 }

---@param canvas wonderland.Canvas
local function drawMeter(canvas)
	canvas:rect(0, 0, canvas.width, canvas.height, meterState.track, meterState.radius)
	canvas:rect(0, 0, canvas.width * meterState.value, canvas.height, meterState.fill, meterState.radius)
end

--- How tall one line of text stands, close enough that the card is cut to it before layout runs.
---@param size number
---@return number
local function lineHeight(size)
	return math.floor(size * 1.35)
end

--- The card's width: the reading column on a desktop, and the page's own width on a phone.
---@param ctx beat.ui.Context
---@return number
local function cardWidth(ctx)
	if ctx.mobile then return ctx.contentWidth end
	return math.min(ctx:px(520), ctx.contentWidth)
end

local CHIP_PAD = 12
local CHIP_ICON = 14
local CHIP_GAP = 6
local CHIP_STEP = 8

--- The width of a chip around a value: the mark, the gap, the value and its padding, up to the
--- card's own width. The value's width is measured by estimate, which is the same figure a button's
--- own width comes from before a font manager exists. The answer is rounded up to a few pixels: the
--- scan names a different file every few frames, and the styles stored against a chip are keyed by
--- its width, so a width that followed every file name would grow that cache for the whole scan.
---@param ctx beat.ui.Context
---@param value string
---@param inner number
---@return number
local function chipWidth(ctx, value, inner)
	local pad = ctx:px(CHIP_PAD)
	local icon = ctx:px(CHIP_ICON)
	local gap = ctx:px(CHIP_GAP)
	local valueWidth = measure.estimate(value, ctx:type("xs"), 0.48)
	local width = math.max(ctx:px(88), pad * 2 + icon + gap + valueWidth)
	width = math.ceil(width / CHIP_STEP) * CHIP_STEP
	return math.min(inner, width)
end

-- The scan's two changing lines, kept against the numbers they were made from: a scan redraws its
-- card every frame and the counts move a few times a second, not thirty.
local progressLine = { tracks = -1, inspected = -1, files = -1, text = "" }
local skippedLine = { count = -1, text = "" }

-- The file the scan is on, cut to the name its chip shows and measured for it. A scan names a new
-- file every few frames, and its basename and chip width are the same while the path is: both are
-- kept against the raw path rather than asked for on every frame in between.
local currentChip = { raw = nil, inner = -1, name = "", width = 0 }

---@param ctx beat.ui.Context
---@param raw string
---@param inner number
---@return string
---@return number
local function scanChip(ctx, raw, inner)
	if currentChip.raw ~= raw or currentChip.inner ~= inner then
		currentChip.raw, currentChip.inner = raw, inner
		currentChip.name = path.basename(raw)
		currentChip.width = currentChip.name ~= "" and chipWidth(ctx, currentChip.name, inner) or 0
	end
	return currentChip.name, currentChip.width
end

---@param tracks number
---@param inspected number
---@param files number
---@return string
local function progressText(tracks, inspected, files)
	if progressLine.tracks ~= tracks or progressLine.inspected ~= inspected or progressLine.files ~= files then
		progressLine.tracks, progressLine.inspected, progressLine.files = tracks, inspected, files
		progressLine.text = format.count(tracks, "track") .. " found · " .. inspected .. " / " .. files .. " files"
	end
	return progressLine.text
end

---@param count number
---@return string
local function skippedText(count)
	if skippedLine.count ~= count then
		skippedLine.count = count
		skippedLine.text = format.count(count, "file") .. " skipped"
	end
	return skippedLine.text
end

---@class beat.components.LibraryEmptyStyles
---@field screen wonderland.StyleBuilder
---@field card wonderland.StyleBuilder
---@field iconBox wonderland.StyleBuilder
---@field iconSize number
---@field iconColour string
---@field title wonderland.StyleBuilder
---@field copy wonderland.StyleBuilder
---@field chip wonderland.StyleBuilder
---@field chipIconSize number
---@field chipIconColour string
---@field chipText wonderland.StyleBuilder
---@field actions wonderland.StyleBuilder
---@field hint wonderland.StyleBuilder
---@field primaryWidth number
---@field rescanWidth number
---@field actionHeight number
---@field meterBox wonderland.StyleBuilder
---@field meterTrack string
---@field meterFill string
---@field meterRadius number
---@field skipped wonderland.StyleBuilder
---@field cancelHeight number
---@field cancelWidth number

--- The shared boxes of a card: the surface, the mark, the title and the copy. `rows` is how many
--- children the card has, which is what its stated height is the sum of, and `extra` is the height
--- of the children only one state has (a chip, a meter and so on).
---@param ctx beat.ui.Context
---@param width number
---@param rows number
---@param extra number
---@param chipWidth number
---@return beat.components.LibraryEmptyStyles
local function cardStyles(ctx, width, rows, extra, chipWidth)
	local pad = ctx:space(ctx.mobile and 24 or 32)
	local gap = ctx:space(12)
	local inner = width - pad * 2
	local iconSize = ctx:px(64)
	local titleSize = ctx:type("xl")
	local copySize = ctx:type("sm")
	local hintSize = ctx:type("xs")
	local titleHeight = lineHeight(titleSize)
	local copyHeight = lineHeight(copySize)
	local hintHeight = lineHeight(hintSize)
	local chipPad = ctx:px(CHIP_PAD)
	local chipIcon = ctx:px(CHIP_ICON)
	local chipGap = ctx:px(CHIP_GAP)
	local height = pad * 2 + iconSize + titleHeight + copyHeight + extra + gap * (rows - 1)

	-- A text box that states its width draws its line from the left, so the lines that fit on one
	-- line do not state one: the card centres its children and each line is as wide as its words.
	-- The chip and the rows are the boxes that do state a width, and their contents are centred
	-- against it.
	return {
		screen = sty():fill():column():align("center"):justify("center"),
		card = sty()
			:w(width):h(height):column():align("center"):justify("center"):pad(pad):gap(gap)
			:radius(ctx:radius("md")):bg(ctx:color("elevated")):border(ctx:px(1), ctx:color("border"))
			:shadow(0, ctx:px(12), ctx:px(30), "#00000099"),
		iconBox = sty()
			:size(iconSize, iconSize):radius(ctx:radius("full")):bg(ctx:color("accent", 0.14)):row():align("center")
			:justify("center"),
		iconSize = ctx:px(28),
		iconColour = ctx:color("text"),
		title = ctx:s():h(titleHeight):text(titleSize):weight("bold"):fg(ctx:color("text")),
		copy = ctx:s():h(copyHeight):text(copySize):fg(ctx:color("muted")),
		chip = sty()
			:w(chipWidth):h(ctx:px(32)):row():align("center"):justify("center"):gap(chipGap)
			:pad(0, chipPad, 0, chipPad):radius(ctx:radius("sm")):bg(ctx:color("hover"))
			:border(ctx:px(1), ctx:color("border")),
		chipIconSize = chipIcon,
		chipIconColour = ctx:color("muted"),
		chipText = ctx:s()
			:w(math.max(ctx:px(1), chipWidth - chipPad * 2 - chipIcon - chipGap)):text(hintSize):fg(ctx:color("muted"))
			:ellipsis(),
		actions = sty():w(inner):h(ctx:px(36)):row():gap(ctx:space(8)):align("center"):justify("center"),
		hint = ctx:s():h(hintHeight):text(hintSize):fg(ctx:color("faint")),
		primaryWidth = ctx:px(160),
		rescanWidth = ctx:px(100),
		actionHeight = ctx:px(36),
		meterBox = sty():w(math.min(inner, ctx:px(320))):h(ctx:px(4)),
		meterTrack = ctx:color("text", 0.1),
		meterFill = ctx:color("accent"),
		meterRadius = ctx:px(4) / 2,
		skipped = ctx:s():h(hintHeight):text(hintSize):fg(ctx:color("danger")),
		cancelHeight = ctx:px(30),
		cancelWidth = ctx:px(110)
	}
end

---@param ctx beat.ui.Context
---@param width number
---@param chipBox number
---@return beat.components.LibraryEmptyStyles
local function emptyCardStyles(ctx, width, chipBox)
	local hasRoot = chipBox > 0
	local extra = (hasRoot and ctx:px(32) or 0) + ctx:px(36) + lineHeight(ctx:type("xs"))
	return cardStyles(ctx, width, hasRoot and 6 or 5, extra, chipBox)
end

---@param ctx beat.ui.Context
---@param width number
---@param chipBox number
---@param hasSkipped number
---@return beat.components.LibraryEmptyStyles
local function scanCardStyles(ctx, width, chipBox, hasSkipped)
	local extra = ctx:px(4)
		+ ctx:px(30)
		+ (chipBox > 0 and ctx:px(32) or 0)
		+ (hasSkipped == 1 and lineHeight(ctx:type("xs")) or 0)
	local rows = 5 + (chipBox > 0 and 1 or 0) + (hasSkipped == 1 and 1 or 0)
	return cardStyles(ctx, width, rows, extra, chipBox)
end

--- A small pill around a folder or a file: the mark, then the value, which ellipsizes rather than
--- setting the card's width when it is a long path.
---@param ctx beat.ui.Context
---@param styles beat.components.LibraryEmptyStyles
---@param iconName string
---@param value string
---@return wonderland.Element
local function chip(ctx, styles, iconName, value)
	local icon = ui.icon(ctx, { name = iconName, size = styles.chipIconSize, colour = styles.chipIconColour })
	return div():style(styles.chip):children(icon, text(value):style(styles.chipText))
end

---@param ctx beat.ui.Context
---@param styles beat.components.LibraryEmptyStyles
---@return wonderland.Element
local function mark(ctx, styles)
	return div()
		:style(styles.iconBox)
		:children(ui.icon(ctx, { name = "library", size = styles.iconSize, colour = styles.iconColour }))
end

-- The lists the cards hand their children over in, reused between frames: the number of children
-- changes with the state, so a build that has fewer than the last drops the leftovers rather than
-- handing the same element to two parents.
local cardChildren = {}
local cardCount = 0
local actionChildren = {}
local actionCount = 0

---@param list wonderland.IntoElement[]
---@param count number
local function trim(list, count)
	for at = count + 1, #list do
		list[at] = nil
	end
end

--- The card with nothing in it: the folder that was read, if there is one, and the two ways to fill
--- it.
---@param app beat.App
---@param ctx beat.ui.Context
---@return wonderland.Element
local function emptyCard(app, ctx)
	local root = app.services.settings.values.root
	local hasRoot = type(root) == "string" and root ~= ""
	local width = cardWidth(ctx)
	local inner = width - ctx:space(ctx.mobile and 24 or 32) * 2
	local chipBox = hasRoot and chipWidth(ctx, root, inner) or 0
	local styles = cache.of(ctx, emptyCardStyles, "libraryEmptyCard", width, chipBox) --[[@as beat.components.LibraryEmptyStyles]]

	cardCount = 1
	cardChildren[1] = mark(ctx, styles)
	cardCount += 1
	cardChildren[cardCount] = text(TITLE):style(styles.title)
	cardCount += 1
	cardChildren[cardCount] = text(hasRoot and ROOT_COPY or CHOOSE_COPY):style(styles.copy)
	if hasRoot then
		cardCount += 1
		cardChildren[cardCount] = chip(ctx, styles, "folder", root)
	end

	actionCount = 1
	actionChildren[1] = ui.button(
		ctx,
		{
			label = "Choose a folder",
			onClick = CHOOSE_FOLDER,
			variant = "primary",
			height = styles.actionHeight,
			width = styles.primaryWidth
		}
	)
	if hasRoot then
		actionCount += 1
		actionChildren[actionCount] = ui.button(
			ctx,
			{ label = "Rescan", onClick = RESCAN, height = styles.actionHeight, width = styles.rescanWidth }
		)
	end
	trim(actionChildren, actionCount)

	cardCount += 1
	cardChildren[cardCount] = div():style(styles.actions):children(actionChildren)
	cardCount += 1
	cardChildren[cardCount] = text(FORMATS):style(styles.hint)
	trim(cardChildren, cardCount)

	return div():style(styles.screen):children(div():style(styles.card):children(cardChildren))
end

--- The card while a scan runs: the phase says what it is doing, the line counts what it has found,
--- the bar fills with the fraction the scan service already reports, and the file it is on is named
--- under it. The cancel button is the one thing offered here, since choosing a folder mid-scan would
--- start another.
---@param app beat.App
---@param ctx beat.ui.Context
---@return wonderland.Element
local function scanCard(app, ctx)
	local scan = app.services.scan
	local job = assert(scan.job)
	local progress = job:progress()
	local current = progress.current
	local raw = type(current) == "string" and current or ""
	local hasSkipped = (progress.skipped or 0) > 0
	local width = cardWidth(ctx)
	local inner = width - ctx:space(ctx.mobile and 24 or 32) * 2
	local currentName, chipBox = scanChip(ctx, raw, inner)
	local styles = cache.of(ctx, scanCardStyles, "libraryScanCard", width, chipBox, hasSkipped and 1 or 0) --[[@as beat.components.LibraryEmptyStyles]]

	meterState.value = math.max(0, math.min(1, scan:fraction()))
	meterState.track, meterState.fill, meterState.radius = styles.meterTrack, styles.meterFill, styles.meterRadius

	cardCount = 1
	cardChildren[1] = mark(ctx, styles)
	cardCount += 1
	cardChildren[cardCount] = text(progress.phase == "enumerate" ? "Finding your music" : "Reading your music")
		:style(styles.title)
	cardCount += 1
	cardChildren[cardCount] = text(progressText(progress.tracks, progress.inspected, progress.files)):style(styles.copy)
	cardCount += 1
	cardChildren[cardCount] = div():style(styles.meterBox):canvas(drawMeter)
	if currentName ~= "" then
		cardCount += 1
		cardChildren[cardCount] = chip(ctx, styles, "musicalNote", currentName)
	end
	if hasSkipped then
		cardCount += 1
		cardChildren[cardCount] = text(skippedText(progress.skipped)):style(styles.skipped)
	end
	cardCount += 1
	cardChildren[cardCount] = ui.button(
		ctx,
		{
			label = "Cancel scan",
			onClick = CANCEL_SCAN,
			variant = "quiet",
			height = styles.cancelHeight,
			width = styles.cancelWidth
		}
	)
	trim(cardChildren, cardCount)

	return div():style(styles.screen):children(div():style(styles.card):children(cardChildren))
end

---@param app beat.App
---@param ctx beat.ui.Context
---@return wonderland.Element
function libraryEmpty.view(app, ctx)
	local scan = app.services.scan
	if scan ~= nil and scan.job ~= nil then return scanCard(app, ctx) end
	return emptyCard(app, ctx)
end

return { view = libraryEmpty.view }
