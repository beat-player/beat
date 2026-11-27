-- The playing track as the whole screen: the cover, the controls and the panels that open from
-- them. It is opened over the page rather than replacing it, so what is left of the app stays
-- underneath while a transition runs.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local albumCard = require("beat.app.components.album_card")
local cover = require("beat.app.components.cover")
local progress = require("beat.app.components.progress")
local spectrumBackground = require("beat.app.components.spectrum_background")
local spinner = require("beat.app.components.spinner")
local styles = require("beat.app.components.helpers.styles")
local metrics = require("beat.app.components.helpers.metrics")
local measure = require("beat.app.components.helpers.measure")
local popup = require("beat.app.components.popup")
local tapButton = require("beat.app.components.tap_button")
local names = require("beat.music.names")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

-- The shuffle button's mode menu and the skip button's group menu, and the mark that says an
-- album or artist shuffle is on.
local SHUFFLE_MENU = { type = "open", overlay = "menu", menu = "shuffle" }
local SKIP_MENU = { type = "open", overlay = "menu", menu = "skip" }
local SHUFFLE = { type = "shuffle" }

-- The screen's own controls: fixed messages, made once rather than once per frame the screen is
-- built again while the playhead moves.
local EXPAND = { type = "expandNowPlaying", open = false }
local TOGGLE_QUEUE = { type = "toggleQueue" }
local TOGGLE_MORE = { type = "toggleMore" }
local TOGGLE_EQUALIZER = { type = "toggleEqualizer" }
local TOGGLE_PLAY = { type = "togglePlay" }
local REPEAT = { type = "repeat" }
local NEXT = { type = "next" }
local PREVIOUS = { type = "previous" }

-- The glyph on the shuffle button's corner badge: the kind of shuffle that is on. A plain track
-- shuffle has no badge, so the button looks as it always has.
local SHUFFLE_BADGES = { albums = "disc", artists = "person" }

--- The three dots at one size and colour. It is made where the button's record is made rather
--- than in the view, so the frame that draws the tool row makes no closure.
---@param size number
---@param colour string
---@return fun(canvas: wonderland.Canvas)
local function moreDraw(size, colour)
	return function(canvas)
		local radius = math.max(1.2, math.floor(size * 0.064))
		local y = math.floor(canvas.height / 2 - radius)
		for at = 0, 2 do
			local x = math.floor(canvas.width / 2 + (at - 1) * size * 0.21 - radius)
			canvas:rect(x, y, radius * 2, radius * 2, colour, radius)
		end
	end
end

-- The equalizer's mark is four bars of fixed levels. They are a constant of the drawing rather
-- than a table made for every frame.
local EQUALIZER_LEVELS = { 0.36, 0.7, 0.48, 0.58 }

--- The equalizer's mark at one size and colour, made where the button's record is made.
---@param inner number
---@param colour string
---@return fun(canvas: wonderland.Canvas)
local function equalizerDraw(inner, colour)
	return function(canvas)
		local barWidth = math.max(2, math.floor(inner * 0.1))
		local gap = math.max(2, math.floor((canvas.width - barWidth * #EQUALIZER_LEVELS) / (#EQUALIZER_LEVELS + 1)))
		for at, level in ipairs(EQUALIZER_LEVELS) do
			local height = math.max(2, math.floor(canvas.height * level))
			local x = math.floor(gap + (at - 1) * (barWidth + gap))
			canvas:rect(x, canvas.height - height, barWidth, height, colour, barWidth / 2)
		end
	end
end

--- The volume control is a button. Its bubble is a sibling of the transport group rather than a
--- child of the button: a positioned panel inside a size-locked button shifted the row's paint
--- order on short windows, clipping the play control.
---@param app beat.App
---@param ctx beat.ui.Context
---@param size number
---@param hit number
local function volumeButton(app, ctx, size, hit)
	local muted = app.services.settings.values.isMuted
	return tapButton.view(ctx, {
		name = muted ? "mute" : "volume",
		size = size,
		hit = hit,
		onClick = { type = "toggleVolume" },
		active = app:overlay("volume") ~= nil
	})
end

--- Three dots, drawn rather than taken from the icon face: the face has no ellipsis, and a
--- text fallback would sit on the wrong baseline next to the other controls.
---@param app beat.App
---@param ctx beat.ui.Context
---@param size number
---@param hit number
---@param onClick any
---@param active boolean?
local function moreButton(app, ctx, size, hit, onClick, active)
	local theme = app.services.appearance.theme
	local colour = active ? (theme:color("text")) : (theme:color("muted"))

	-- The dots depend on the size and the colour, and both are the same on every frame the button
	-- is drawn: the draw is kept with the theme, one for each pair.
	local byColour = styles.of(theme, "nowPlayingMore", size) --[[@as table<string, fun(canvas: wonderland.Canvas)>]]
	local draw = byColour[colour]
	if draw == nil then
		draw = moreDraw(size, colour)
		byColour[colour] = draw
	end

	return ui.iconButton(ctx, {
		size = hit,
		onClick = onClick,
		content = div():style(sty():size(size, size)):canvas(draw)
	})
end

--- The shuffle control. A plain on/off shuffle is the tap button every other tool is; a grouped
--- shuffle adds the mode's small glyph on a filled circle at the button's corner, so the icon says
--- which kind of shuffle is running.
---@param app beat.App
---@param ctx beat.ui.Context
---@param size number
---@param hit number
---@param mode beat.ShuffleMode
---@return wonderland.Element
local function shuffleButton(app, ctx, size, hit, mode)
	local badge = SHUFFLE_BADGES[mode]
	if badge == nil then
		return tapButton.view(ctx, { name = "shuffle", size = size, hit = hit, onClick = SHUFFLE, active = mode ~= "off" })
	end

	local theme = app.services.appearance.theme
	local glyphSize = math.max(18, math.floor(size * 0.8 + 0.5))
	local badgeSize = math.max(theme:px(13), math.floor(size * 0.5 + 0.5))
	local byKey = styles.of(theme, "nowPlayingShuffleMark", hit) --[[@as table<string, any>]]
	local key = glyphSize .. ":" .. badgeSize
	local set = byKey[key]
	if set == nil then
		set = {
			content = sty():size(hit, hit),
			glyph = sty():size(glyphSize, glyphSize):offset((hit - glyphSize) / 2, (hit - glyphSize) / 2),
			badge = sty()
				:size(badgeSize, badgeSize):radius(theme:radius("full")):bg(theme:color("bg")):align("center")
				:justify("center"):offset(hit - badgeSize, hit - badgeSize),
			badgeGlyph = math.max(8, math.floor(badgeSize * 0.72 + 0.5))
		}
		byKey[key] = set
	end
	return ui.iconButton(ctx, {
		size = hit,
		onClick = SHUFFLE,
		content = div():style(set.content):children({
			div():style(set.glyph):children(ui.icon(ctx, {
				name = "shuffle",
				size = glyphSize,
				colour = theme:color("text")
			})),
			div():style(set.badge):children(ui.icon(ctx, {
				name = badge,
				size = set.badgeGlyph,
				colour = theme:color("accent")
			}))
		})
	})
end

--- The equalizer has no behaviour yet, so this is only its mark: four static bars, quieter than
--- the playing indicator because nothing here is measuring audio.
---@param app beat.App
---@param ctx beat.ui.Context
---@param size number
---@param hit number
---@param onClick any
---@param active boolean?
local function equalizerButton(app, ctx, size, hit, onClick, active)
	local theme = app.services.appearance.theme
	local colour = active ? (theme:color("text")) : (theme:color("muted"))
	local inner = math.max(12, math.floor(size * 0.72 + 0.5))

	local byColour = styles.of(theme, "nowPlayingEqualizer", inner) --[[@as table<string, fun(canvas: wonderland.Canvas)>]]
	local draw = byColour[colour]
	if draw == nil then
		draw = equalizerDraw(inner, colour)
		byColour[colour] = draw
	end

	return ui.iconButton(ctx, {
		size = hit,
		onClick = onClick,
		content = div():style(sty():size(inner, inner)):canvas(draw)
	})
end

-- The rating a track's stars send, one handler per track rather than one per frame the screen is
-- drawn. The screen is built again whenever the playhead moves.
---@type table<beat.Track, fun(stars: number): table>
local rateHandlers = setmetatable({}, { __mode = "k" })

---@param track beat.Track
---@return fun(stars: number): table
local function rateFor(track)
	local handler = rateHandlers[track]
	if handler == nil then
		local id = track.id
		handler = |stars| -> { type = "rateTrack", id = id, stars = stars }
		rateHandlers[track] = handler
	end
	return handler
end

---@class beat.ToolRoom
---@field below number # How far the window goes under the now-playing tool row
---@field above number # And over it
---@field top number # Where the tool row's top is from the top of the box a panel is offset from
---@field rowHeight number # The tool row's own height, which the panel clears to sit beside it

--- Places a panel opened from the now-playing tool row: under the row where it fits or where
--- there is more room below than above, over it otherwise. It pops out of the row the way it
--- opens, from the motion `key` its overlay started (see `beat.components.popup`).
---@param app beat.App
---@param panel wonderland.Element
---@param x number # From the row's left edge
---@param width number
---@param height number
---@param room beat.ToolRoom
---@param key string
---@return wonderland.Element
local function toolPanel(app, panel, x, width, height, room, key)
	local theme = app.services.appearance.theme
	local gap = theme:px(6)
	local below = height + gap <= room.below or room.below >= room.above
	local y = room.top + (below and (room.rowHeight + gap) or -(height + gap))
	return popup.view(app, { key = key, panel = panel, x = x, y = y, width = width, height = height, grows = below and "down" or "up" })
end

--- Draws a panel at the button that opened it. The anchor -- where the controls row is, and how
--- much room there is on either side of it -- is this screen's to work out: the panel only knows
--- how big it is.
---@param app beat.App
---@param name string
---@param anchor table
---@param window wonderland.RenderWindow
local function anchored(app, name, anchor, window)
	local overlay = app:overlay(name)
	local surface = app.registry:overlay(name)
	if overlay == nil or surface.view == nil then return nil end
	overlay.state.anchor = anchor
	return surface.view(app, overlay, window)
end

---@class beat.NowPlayingState: beat.OverlayState
---@field anchor table?
---@field room table? # Where the tool row is and how much room is around it, written each frame
---@field volumeAnchor table? # The panel anchors kept for each popup, written rather than replaced
---@field queueAnchor table?
---@field menuAnchor table?

---@class beat.NowPlayingOverlay: beat.OverlaySurface
---@field toolPanel fun(app: beat.App, panel: wonderland.Element, x: number, width: number, height: number, room: beat.ToolRoom, key: string): wonderland.Element

--- The styles of the screen that depend on the theme alone: the tool row and the marks in it are
--- the same for every track and every window size, and this screen is built again whenever what is
--- playing changes, so they are kept on the theme rather than made again with it.
---@class beat.NowPlayingStyles
---@field toolSize number
---@field toolHit number
---@field toolGap number
---@field toolGroupWidth number
---@field toolRowHeight number
---@field header wonderland.StyleBuilder
---@field toolGroup wonderland.StyleBuilder
---@field toolRow wonderland.StyleBuilder
---@field screen wonderland.StyleBuilder

---@param theme beat.Theme
---@param mobile boolean
---@return beat.NowPlayingStyles
local function screenStyles(theme, mobile)
	---@type table<string, any>
	local cache = theme:cache()
	local key = mobile and "nowPlayingMobile" or "nowPlaying"
	local styles = cache[key] --[[@as beat.NowPlayingStyles?]]
	if styles ~= nil then return styles end

	local toolSize = theme:px(28)
	local toolGap = theme:px(4)
	-- On a phone the tool marks stay the size they are, but the row and each box grow to a thumb:
	-- a 28 px glyph is a fine mark and a poor target.
	local toolHit = mobile and theme:px(48) or toolSize
	local toolGroupWidth = toolHit * 2 + toolGap
	local rowHeight = mobile and theme:px(48) or theme:px(34)
	styles = {
		toolSize = toolSize,
		toolHit = toolHit,
		toolGap = toolGap,
		toolGroupWidth = toolGroupWidth,
		toolRowHeight = rowHeight,
		header = sty():row():wrel(1.0):h(mobile and theme:px(48) or theme:px(36)):justify("end"):align("center")
			:offset(0, 0):z(110),
		toolGroup = sty():row():w(toolGroupWidth):h(rowHeight):gap(toolGap):align("center"),
		toolRow = sty():row():wrel(1.0):h(rowHeight):align("center"):justify("space-between"),
		screen = sty()
			:fill():offset(0, 0):z(100):column():bg(theme:color("bg")):fg(theme:color("text")):font(theme.fontFamily)
	}
	cache[key] = styles

	return styles
end

-- Where the album and artist lines lead. The message for an album or an artist is the same for the
-- life of the thing it names, and the screen is built again whenever the playhead moves.
---@type table<beat.Album, table>
local albumNavigations = setmetatable({}, { __mode = "k" })
---@type table<number, table>
local artistNavigations = {}

---@param album beat.Album
---@return table
local function navigateAlbum(album)
	local message = albumNavigations[album]
	if message == nil then
		message = { type = "navigate", page = { kind = "album", id = album.id } }
		albumNavigations[album] = message
	end
	return message
end

---@param artistId number
---@return table
local function navigateArtist(artistId)
	local message = artistNavigations[artistId]
	if message == nil then
		message = { type = "navigate", page = { kind = "artist", id = artistId } }
		artistNavigations[artistId] = message
	end
	return message
end

--- The title block's styles for one width and phone/desktop type. The album and artist boxes are
--- cut to their measured text, so those measurements are part of the record: a new track or album
--- rebuilds it once, and the frames of one track reuse it.
---@class beat.NowPlayingSection
---@field width number
---@field mobile boolean
---@field albumItem beat.Album?
---@field artistName string?
---@field subtitleType number
---@field lineHeight number
---@field sepWidth number
---@field subtitle wonderland.StyleBuilder
---@field title wonderland.StyleBuilder
---@field album wonderland.StyleBuilder
---@field albumHover wonderland.StyleBuilder
---@field sep wonderland.StyleBuilder
---@field artist wonderland.StyleBuilder
---@field artistHover wonderland.StyleBuilder
---@field line wonderland.StyleBuilder

---@param theme beat.Theme
---@param app beat.App
---@param mobile boolean
---@param width number
---@param album beat.Album
---@param artist string
---@param subtitleType number
---@return beat.NowPlayingSection
local function sectionStyles(theme, app, mobile, width, album, artist, subtitleType)
	local byMobile = styles.of(theme, "nowPlayingSection", width)
	local key = mobile and 1 or 0
	local record = byMobile[key] --[[@as beat.NowPlayingSection?]]
	if
		record ~= nil
		and record.albumItem == album
		and record.artistName == artist
		and record.subtitleType == subtitleType
	then
		return record
	end

	local subtitle = record ~= nil and record.subtitleType == subtitleType and record.subtitle
		or theme:s():text(subtitleType):weight("medium")
	local lineHeight = math.floor(subtitleType * 1.3)
	local sepWidth = math.ceil(measure.width(app, "  ·  ", subtitle) or theme:px(24))
	local albumWidth = math.ceil(measure.width(app, album.title, subtitle) or width) + 1
	local artistWidth = math.ceil(measure.width(app, artist, subtitle) or width) + 1
	local room = width - sepWidth
	if albumWidth + artistWidth > room then
		artistWidth = math.min(artistWidth, math.floor(room * 0.4))
		albumWidth = math.max(math.floor(room * 0.6), room - artistWidth)
		artistWidth = room - albumWidth
	end

	record = {
		width = width,
		mobile = mobile,
		albumItem = album,
		artistName = artist,
		subtitleType = subtitleType,
		lineHeight = lineHeight,
		sepWidth = sepWidth,
		subtitle = subtitle,
		title = theme:s():w(width):text(theme:type(mobile and "xxl" or "hero")):weight("bold"):fg(theme:color("text")):ellipsis(),
		album = theme:s():w(albumWidth):text(subtitleType):weight("medium"):fg(theme:color("muted")):ellipsis(),
		albumHover = theme:s():w(albumWidth):text(subtitleType):weight("medium"):fg(theme:color("text")):ellipsis(),
		sep = theme:s():w(sepWidth):text(subtitleType):weight("medium"):fg(theme:color("muted")),
		artist = theme:s():w(artistWidth):text(subtitleType):weight("medium"):fg(theme:color("muted")):ellipsis(),
		artistHover = theme:s():w(artistWidth):text(subtitleType):weight("medium"):fg(theme:color("text")):ellipsis(),
		line = sty():row():w(width):h(lineHeight):align("center")
	}
	byMobile[key] = record
	return record
end

--- The stage's boxes for one width and phone/desktop layout. The record keeps the numbers its
--- builders were made from, so a resize or a different track rebuilds it once and every frame in
--- between hands the same builders over again.
---@class beat.NowPlayingStage
---@field width number
---@field stacked boolean
---@field availableHeight number
---@field mainPad number
---@field gap number
---@field stageGap number
---@field coverSize number
---@field textHeight number
---@field stageHeight number
---@field controlHeight number
---@field playSize number
---@field skipHit number
---@field controlGap number
---@field margin number
---@field topInset number
---@field cover wonderland.StyleBuilder
---@field spacer wonderland.StyleBuilder
---@field playGroup wonderland.StyleBuilder
---@field playCircle wonderland.StyleBuilder
---@field controls wonderland.StyleBuilder
---@field main wonderland.StyleBuilder
---@field textColumn wonderland.StyleBuilder

---@param theme beat.Theme
---@param mobile boolean
---@param width number
---@return beat.NowPlayingStage
local function stageRecord(theme, mobile, width)
	local byMobile = styles.of(theme, "nowPlayingStage", width)
	local key = mobile and 1 or 0
	local record = byMobile[key] --[[@as beat.NowPlayingStage?]]
	if record == nil then
		record = { width = width, stacked = false }
		byMobile[key] = record
	end
	return record
end

---@param theme beat.Theme
---@param stage beat.NowPlayingStage
---@param stacked boolean
local function buildStage(theme, stage, stacked)
	local radius = theme:radius("full")
	stage.cover = sty():size(stage.coverSize, stage.coverSize):shadow(0, 8, 14, "#00000038")
	stage.spacer = sty():w("auto"):h(stage.controlHeight)
	stage.playGroup = sty()
		:row():w(stage.skipHit * 2 + stage.playSize + stage.controlGap * 2):h(stage.controlHeight)
		:gap(stage.controlGap):align("center"):justify("center")
	stage.playCircle = sty():size(stage.playSize, stage.playSize):radius(radius):bg(theme:color("accent")):align("center")
		:justify("center")
	stage.controls = sty():row():wrel(1.0):h(stage.controlHeight):align("center")
	stage.main = stacked
			and sty()
				:h(stage.availableHeight):column():align("center"):justify("center"):gap(stage.stageGap)
				:pad(stage.mainPad, 0, stage.mainPad, 0)
		or sty()
			:h(stage.availableHeight):row():align("center"):justify("center"):gap(stage.gap)
			:pad(stage.mainPad, 0, stage.mainPad, 0)
	stage.textColumn = stacked
			and sty():column():h(stage.textHeight):gap(stage.stageGap):w(stage.width)
		or sty():column():h(stage.stageHeight):justify("center"):gap(stage.stageGap):w(stage.width)
end

--- The padded content around the stage, for the margin and the status bar it has to clear.
---@param theme beat.Theme
---@param top number
---@param side number
---@return wonderland.StyleBuilder
local function contentStyle(theme, top, side)
	local bySide = styles.of(theme, "nowPlayingContent", top)
	local style = bySide[side]
	if style == nil then
		style = sty():fill():column():pad(top, side, side, side):gap(theme:space(16))
		bySide[side] = style
	end
	return style
end

---@type beat.NowPlayingOverlay
local nowPlaying = { fullscreen = true }

nowPlaying.toolPanel = toolPanel

---@param app beat.App
function nowPlaying.new(app)
	app.services.motion.clock:animate("nowPlaying", 1, 0.28, app.services.motion.ease.outBack)
	return {}
end

---@param app beat.App
---@param _overlay beat.OverlayInstance<beat.NowPlayingState>
function nowPlaying.close(app, _overlay)
	app.services.motion.clock:animate("nowPlaying", 0, 0.28, app.services.motion.ease.inCubic)
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.NowPlayingState>
---@param message beat.Message
function nowPlaying.update(app, overlay, message)
	if message.type == "expandNowPlaying" then
		-- The screen's own chevron. It closes this screen and every panel opened from it, not just
		-- whichever panel happens to be on top.
		if message.open ~= true then app:close(overlay) end
	elseif message.type == "toggleVolume" then
		app:open("volume")
	elseif message.type == "toggleQueue" then
		app:open("queue")
	elseif message.type == "toggleMore" then
		app:open("more")
	elseif message.type == "toggleEqualizer" then
		app:open("equalizer")
	else
		return false
	end
	return true
end

---@param app beat.App
---@param _overlay beat.OverlayInstance<beat.NowPlayingState>
---@param window wonderland.RenderWindow
---@return wonderland.Element
function nowPlaying.view(app, overlay, window)
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local state = overlay.state
	local mobile = metrics.mobile(app, window.width)
	local stacked = mobile and window.height >= theme:px(560)
	local track = app.services.playback:current()
	---@type beat.Album?
	local album
	local library = app.services.library
	if track ~= nil and library.current ~= nil then album = library.current:album(track.albumId) end
	local margin = mobile ? (theme:space(16)) : math.max(
		((theme:space(10))),
		math.min(((theme:space(28))), math.floor(window.width * 0.03), math.floor(window.height * 0.03))
	)
	local availableWidth = window.width - margin * 2
	-- A full-screen overlay starts at the window's edge, but Android draws the status bar over it:
	-- the header has to clear the same inset the shell's pages sit under.
	local topInset = metrics.insets()
	local availableHeight = window.height - margin * 2 - topInset
	local mainPad = math.min(theme:space(32), math.max(theme:px(12), math.floor(availableHeight * 0.06)))
	local gap = theme:space(32)
	local desiredProgress = window.width >= 1240 ? (theme:px(600)) : (theme:px(380))
	local compact = availableHeight < theme:px(430)
	local stageGap = compact ? (theme:px(6)) : (theme:px(10))

	local screen = screenStyles(theme, mobile)
	local header = div():style(screen.header):children({
		tapButton.view(ctx, {
			name = "chevronDown",
			size = theme:px(34),
			hit = mobile and theme:px(48) or theme:px(34),
			onClick = EXPAND
		})
	})
	local contentChildren = {}

	if track ~= nil and album ~= nil then
		local coverSize
		local progressWidth
		local stackGap = theme:space(24)
		if stacked then
			-- The cover is the page's one picture, and a little larger than the album page's: what is
			-- left of the window's height after it is what the title block and the controls share.
			coverSize = math.min(theme:px(340), availableWidth, math.floor(availableHeight * 0.46))
			progressWidth = math.max(theme:px(160), availableWidth - mainPad * 2)
		else
			coverSize = math.min(theme:px(390), math.floor(availableWidth * 0.27), math.floor(availableHeight * 0.43))
			local maxText = availableWidth - coverSize - gap
			if maxText < theme:px(180) then
				coverSize = math.max(theme:px(64), availableWidth - gap - theme:px(180))
				maxText = availableWidth - coverSize - gap
			end
			progressWidth = math.max(theme:px(160), math.min(desiredProgress, maxText))
		end
		local stageHeight = math.min(theme:px(340), math.max(theme:px(220), availableHeight - screen.toolRowHeight - mainPad * 2))

		local transport = math.max(0.7, math.min(1, progressWidth / theme:px(240)))
		local controlGap = theme:px(10 * transport)
		-- The album and artist are secondary: body type on a phone, where the larger desktop line
		-- would compete with the title, and the size it always was on a desktop.
		local subtitleType = theme:type(mobile ? "md" : "lg")
		local section = sectionStyles(theme, app, mobile, progressWidth, album, track.artist, subtitleType)

		local controlHeight = theme:px(54 * transport)
		local skipSize = theme:px(30 * transport)
		local skipHit = mobile and theme:px(56) or skipSize
		local sideHit = mobile and theme:px(48) or theme:px(28 * transport)
		local playSize = theme:px(54 * transport)
		if mobile then controlHeight = math.max(controlHeight, skipHit) end
		local titleSize = (theme:type(mobile ? "xxl" : "hero"))
		local progressHeight = progress.height(theme, mobile)
		local textHeight = titleSize + subtitleType + screen.toolRowHeight + progressHeight + controlHeight + stageGap * 4

		local stage = stageRecord(theme, mobile, progressWidth)
		local rebuild = stage.stacked ~= stacked
			or stage.availableHeight ~= availableHeight
			or stage.mainPad ~= mainPad
			or stage.gap ~= gap
			or stage.stageGap ~= stageGap
			or stage.coverSize ~= coverSize
			or stage.textHeight ~= textHeight
			or stage.stageHeight ~= stageHeight
			or stage.controlHeight ~= controlHeight
			or stage.playSize ~= playSize
			or stage.skipHit ~= skipHit
			or stage.controlGap ~= controlGap
			or stage.margin ~= margin
			or stage.topInset ~= topInset
		stage.stacked = stacked
		stage.availableHeight = availableHeight
		stage.mainPad = mainPad
		stage.gap = gap
		stage.stageGap = stageGap
		stage.coverSize = coverSize
		stage.textHeight = textHeight
		stage.stageHeight = stageHeight
		stage.controlHeight = controlHeight
		stage.playSize = playSize
		stage.skipHit = skipHit
		stage.controlGap = controlGap
		stage.margin = margin
		stage.topInset = topInset
		if rebuild then buildStage(theme, stage, stacked) end

		local coverFrame = div():style(stage.cover):onClick(navigateAlbum(album)):onContextMenu(albumCard.actions(album).menu):children(
			cover.view(app, { album = album, size = coverSize, radius = theme:radius("lg"), glow = true })
		)
		local textRows = {
			text(track.title):style(section.title),
			div():style(section.line):children({
				text(album.title)
					:style(section.album)
					:hover(section.albumHover)
					:onClick(navigateAlbum(album)),
				text("  ·  ")
					:style(section.sep),
				text(track.artist)
					:style(section.artist)
					:hover(section.artistHover)
					:onClick(navigateArtist(track.artistId))
			})
		}
		local queue = app.services.playback.player.queue
		local repeatIcon = queue?.repeatMode == "one" ? "repeatOne" : "repeat"
		local repeatActive = queue ~= nil and queue.repeatMode ~= "off"
		local toolSize = screen.toolSize
		local toolHit = screen.toolHit
		local toolGap = screen.toolGap
		local toolGroupWidth = screen.toolGroupWidth
		local toolChildren = {
			div():style(screen.toolGroup):children({
				tapButton.view(ctx, {
					name = "queue",
					size = toolSize,
					hit = toolHit,
					onClick = TOGGLE_QUEUE,
					active = app:overlay("queue") ~= nil
				}),
				moreButton(app, ctx, toolSize, toolHit, TOGGLE_MORE, app:overlay("more") ~= nil)
			})
		}
		-- The rating sits between the two groups where the row has room for it; a narrow stage
		-- still has it at the top of the three dots' menu.
		local starSize = theme:px(16)
		local starGap = theme:px(2)
		if app.registry:hasPlugin("ratings") and progressWidth - toolGroupWidth * 2 >= starSize * 5 + starGap * 4 + theme:px(24) then
			toolChildren[#toolChildren + 1] = ui.rating(ctx, {
				value = app.services.collections.taxonomy:rating(names.trackKey(track)),
				onRate = rateFor(track),
				size = starSize,
				gap = starGap
			})
		end
		local shuffleMode = queue ~= nil and queue.shuffleMode or "off"
		local shuffle = shuffleButton(app, ctx, toolSize, toolHit, shuffleMode)
		shuffle:onContextMenu(SHUFFLE_MENU)
		toolChildren[#toolChildren + 1] = div():style(screen.toolGroup):children({
			shuffle,
			tapButton.view(ctx, {
				name = repeatIcon,
				size = toolSize,
				hit = toolHit,
				onClick = REPEAT,
				active = repeatActive
			})
		})
		textRows[#textRows + 1] = div():style(screen.toolRow):children(toolChildren)
		textRows[#textRows + 1] = progress.view(app, {
			track = track,
			player = app.services.playback.player,
			width = progressWidth,
			mobile = mobile
		})

		-- The transport is centred by a spacer either side rather than by spreading the row: the
		-- panels below are boxes offset from the row, and a spread row still counts them among the
		-- boxes it spreads, which moved the transport towards them. The spacers share what the
		-- other boxes leave, so the transport says how wide it is.
		local playing = app.services.playback.player:isPlaying()
		local playMark = app.services.playback.player:isLoading()
				and spinner.view(app, theme:px(24 * transport), theme.accentInk)
			or ui.icon(ctx, { name = playing ? "pause" : "play", size = theme:px(24 * transport), colour = theme.accentInk })
		local nextButton = tapButton.view(ctx, { name = "next", size = skipSize, hit = skipHit, onClick = NEXT })
		nextButton:onContextMenu(SKIP_MENU)
		local controlChildren = {
			volumeButton(app, ctx, theme:px(28 * transport), sideHit),
			div():style(stage.spacer),
			div():style(stage.playGroup):children({
				tapButton.view(ctx, { name = "previous", size = skipSize, hit = skipHit, onClick = PREVIOUS }),
				div():style(stage.playCircle):onClick(TOGGLE_PLAY):children(playMark),
				nextButton
			}),
			div():style(stage.spacer),
			equalizerButton(app, ctx, theme:px(28 * transport), sideHit, TOGGLE_EQUALIZER, app:overlay("equalizer") ~= nil)
		}

		-- The panels opened from the tool row are placed from the row's place and the room around
		-- it. Their anchor records live on this screen's state rather than being made per frame;
		-- each popup keeps the one named for it, and its numbers are written in place.
		local panelHeight = theme:px(44)
		local volumeAnchor = state.volumeAnchor
		if volumeAnchor == nil then
			volumeAnchor = { x = 0 }
			state.volumeAnchor = volumeAnchor
		end
		volumeAnchor.width = theme:px(190)
		volumeAnchor.height = panelHeight
		volumeAnchor.y = compact and (-panelHeight - theme:px(8)) or (controlHeight + theme:px(8))
		local volumePanel = anchored(app, "volume", volumeAnchor, window)
		if volumePanel ~= nil then
			controlChildren[#controlChildren + 1] = volumePanel
		end

		local lead = stacked and (coverSize + stackGap) or 0
		local rowTop = margin + mainPad + (availableHeight - mainPad * 2 - lead - textHeight) / 2 + lead + titleSize + subtitleType + stageGap * 2
		local edge = theme:px(12)
		local room = state.room
		if room == nil then
			room = {}
			state.room = room
		end
		room.below = window.height - edge - rowTop - screen.toolRowHeight
		room.above = rowTop - edge
		room.top = -(screen.toolRowHeight + progressHeight + stageGap * 2)
		room.rowHeight = screen.toolRowHeight
		local queueAnchor = state.queueAnchor
		if queueAnchor == nil then
			queueAnchor = { room = room }
			state.queueAnchor = queueAnchor
		end
		queueAnchor.toolWidth = progressWidth
		queueAnchor.room = room
		local queuePanel = anchored(app, "queue", queueAnchor, window)
		if queuePanel ~= nil then
			controlChildren[#controlChildren + 1] = queuePanel
		end
		local menuAnchor = state.menuAnchor
		if menuAnchor == nil then
			menuAnchor = { room = room }
			state.menuAnchor = menuAnchor
		end
		menuAnchor.rowWidth = progressWidth
		menuAnchor.room = room
		menuAnchor.x = toolHit + toolGap
		local menu = anchored(app, "more", menuAnchor, window)
		if menu ~= nil then
			controlChildren[#controlChildren + 1] = menu
		end
		textRows[#textRows + 1] = div():style(stage.controls):children(controlChildren)

		contentChildren[#contentChildren + 1] = div():style(stage.main):children({
			coverFrame,
			div():style(stage.textColumn):children(textRows)
		})
	end
	contentChildren[#contentChildren + 1] = header

	-- The FFT belongs to the window, not to the padded content: the content's gutter only
	-- positions the controls, while the background bars run to every edge.
	local content = div():style(contentStyle(theme, margin + topInset, margin)):children(contentChildren)

	local children = { spectrumBackground.view(app, { intensity = 0.7, reach = 0.8, bold = true }), content }

	return div():style(screen.screen):children(children)
end

return nowPlaying
