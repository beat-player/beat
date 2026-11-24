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
function nowPlaying.view(app, _overlay, window)
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
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

	local styles = screenStyles(theme, mobile)
	local header = div():style(styles.header):children({
		tapButton.view(ctx, {
			name = "chevronDown",
			size = theme:px(34),
			hit = mobile and theme:px(48) or theme:px(34),
			onClick = { type = "expandNowPlaying", open = false }
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
		local stageHeight = math.min(theme:px(340), math.max(theme:px(220), availableHeight - styles.toolRowHeight - mainPad * 2))

		local coverFrame = div():style(sty():size(coverSize, coverSize):shadow(0, 12, 20, "#00000060")):onClick({
			type = "navigate",
			page = { kind = "album", id = album.id }
		}):onContextMenu(albumCard.actions(album).menu):children(
			cover.view(app, { album = album, size = coverSize, radius = theme:radius("lg"), glow = true })
		)
		local transport = math.max(0.7, math.min(1, progressWidth / theme:px(240)))
		local controlGap = theme:px(10 * transport)
		-- The album and artist are secondary: body type on a phone, where the larger desktop line
		-- would compete with the title, and the size it always was on a desktop.
		local subtitleType = theme:type(mobile ? "md" : "lg")
		-- The album and artist sit at their own widths, so the dot stays between them; only when
		-- the two do not fit together are they cut, the artist keeping its whole name where that is
		-- short and the album never giving up more than two fifths of the line.
		local lineHeight = math.floor(subtitleType * 1.3)
		local subtitleStyle = theme:s():text(subtitleType):weight("medium")
		local sepWidth = math.ceil(measure.width(app, "  ·  ", subtitleStyle) or theme:px(24))
		local albumWidth = math.ceil(measure.width(app, album.title, subtitleStyle) or progressWidth) + 1
		local artistWidth = math.ceil(measure.width(app, track.artist, subtitleStyle) or progressWidth) + 1
		local room = progressWidth - sepWidth
		if albumWidth + artistWidth > room then
			artistWidth = math.min(artistWidth, math.floor(room * 0.4))
			albumWidth = math.max(math.floor(room * 0.6), room - artistWidth)
			artistWidth = room - albumWidth
		end
		local textRows = {
			text(track.title)
				:style(
					theme:s()
						:w(progressWidth):text(((theme:type(mobile ? "xxl" : "hero")))):weight("bold"):fg(theme:color("text")):ellipsis()
				),
			div():style(sty():row():w(progressWidth):h(lineHeight):align("center")):children({
				text(album.title)
					:style(theme:s():w(albumWidth):text(subtitleType):weight("medium"):fg(theme:color("muted")):ellipsis())
					:hover(theme:s():w(albumWidth):text(subtitleType):weight("medium"):fg(theme:color("text")):ellipsis())
					:onClick({ type = "navigate", page = { kind = "album", id = album.id } }),
				text("  ·  ")
					:style(theme:s():w(sepWidth):text(subtitleType):weight("medium"):fg(theme:color("muted"))),
				text(track.artist)
					:style(theme:s():w(artistWidth):text(subtitleType):weight("medium"):fg(theme:color("muted")):ellipsis())
					:hover(theme:s():w(artistWidth):text(subtitleType):weight("medium"):fg(theme:color("text")):ellipsis())
					:onClick({ type = "navigate", page = { kind = "artist", id = track.artistId } })
			})
		}
		local queue = app.services.playback.player.queue
		local repeatIcon = queue?.repeatMode == "one" ? "repeatOne" : "repeat"
		local repeatActive = queue ~= nil and queue.repeatMode ~= "off"
		local toolSize = styles.toolSize
		local toolHit = styles.toolHit
		local toolGap = styles.toolGap
		local toolGroupWidth = styles.toolGroupWidth
		local toolChildren = {
			div():style(styles.toolGroup):children({
				tapButton.view(ctx, {
					name = "queue",
					size = toolSize,
					hit = toolHit,
					onClick = { type = "toggleQueue" },
					active = app:overlay("queue") ~= nil
				}),
				moreButton(app, ctx, toolSize, toolHit, { type = "toggleMore" }, app:overlay("more") ~= nil)
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
		toolChildren[#toolChildren + 1] = div():style(styles.toolGroup):children({
			tapButton.view(ctx, {
				name = "shuffle",
				size = toolSize,
				hit = toolHit,
				onClick = { type = "shuffle" },
				active = queue?.shuffle ?? false
			}),
			tapButton.view(ctx, {
				name = repeatIcon,
				size = toolSize,
				hit = toolHit,
				onClick = { type = "repeat" },
				active = repeatActive
			})
		})
		textRows[#textRows + 1] = div():style(styles.toolRow):children(toolChildren)
		textRows[#textRows + 1] = progress.view(app, {
			track = track,
			player = app.services.playback.player,
			width = progressWidth,
			mobile = mobile
		})
		local controlHeight = theme:px(54 * transport)
		-- The transport is centred by a spacer either side rather than by spreading the row: the
		-- panels below are boxes offset from the row, and a spread row still counts them among the
		-- boxes it spreads, which moved the transport towards them. The spacers share what the
		-- other boxes leave, so the transport says how wide it is.
		local skipSize = theme:px(30 * transport)
		local skipHit = mobile and theme:px(56) or skipSize
		local sideHit = mobile and theme:px(48) or theme:px(28 * transport)
		local playSize = theme:px(54 * transport)
		if mobile then controlHeight = math.max(controlHeight, skipHit) end
		local playing = app.services.playback.player:isPlaying()
		local playMark = app.services.playback.player:isLoading()
				and spinner.view(app, theme:px(24 * transport), theme.accentInk)
			or ui.icon(ctx, { name = playing ? "pause" : "play", size = theme:px(24 * transport), colour = theme.accentInk })
		local controlChildren = {
			volumeButton(app, ctx, theme:px(28 * transport), sideHit),
			div():style(sty():w("auto"):h(controlHeight)),
			div():style(sty():row():w(skipHit * 2 + playSize + controlGap * 2):h(controlHeight):gap(controlGap):align("center"):justify("center")):children({
				tapButton.view(ctx, { name = "previous", size = skipSize, hit = skipHit, onClick = { type = "previous" } }),
				div():style(sty():size(playSize, playSize):radius(theme:radius("full")):bg(theme:color("accent")):align("center"):justify("center")):onClick({
					type = "togglePlay"
				}):children(playMark),
				tapButton.view(ctx, { name = "next", size = skipSize, hit = skipHit, onClick = { type = "next" } })
			}),
			div():style(sty():w("auto"):h(controlHeight)),
			equalizerButton(app, ctx, theme:px(28 * transport), sideHit, { type = "toggleEqualizer" }, app:overlay("equalizer") ~= nil)
		}
		local panelHeight = theme:px(44)
		local volumePanel = anchored(app, "volume", {
			width = theme:px(190),
			height = panelHeight,
			x = 0,
			y = compact and (-panelHeight - theme:px(8)) or (controlHeight + theme:px(8))
		}, window)
		if volumePanel ~= nil then controlChildren[#controlChildren + 1] = volumePanel end
		local titleSize = (theme:type(mobile ? "xxl" : "hero"))
		local progressHeight = progress.height(theme, mobile)
		local textHeight = titleSize + subtitleType + styles.toolRowHeight + progressHeight + controlHeight + stageGap * 4

		-- The queue and the menu open from the tool row, towards whichever side of it has the room.
		-- Where the row is comes from the sizes the stage is centred with -- a line of text is as
		-- tall as its type -- so the panels can be sized before the layout has run.
		local lead = stacked and (coverSize + stackGap) or 0
		local rowTop = margin + mainPad + (availableHeight - mainPad * 2 - lead - textHeight) / 2 + lead + titleSize + subtitleType + stageGap * 2
		local edge = theme:px(12)
		-- They are offset from the controls, the last row of the stage, rather than from the tool
		-- row: what is painted later than a panel and under its shadow is not painted at all, and
		-- nothing in the stage is painted later than its last row. The tool row is a fixed distance
		-- above it.
		local room = {
			below = window.height - edge - rowTop - styles.toolRowHeight,
			above = rowTop - edge,
			top = -(styles.toolRowHeight + progressHeight + stageGap * 2),
			rowHeight = styles.toolRowHeight
		}
		local queuePanel = anchored(app, "queue", { toolWidth = progressWidth, room = room }, window)
		if queuePanel ~= nil then controlChildren[#controlChildren + 1] = queuePanel end
		local menu = anchored(app, "more", { rowWidth = progressWidth, room = room, x = toolHit + toolGap }, window)
		if menu ~= nil then controlChildren[#controlChildren + 1] = menu end
		textRows[#textRows + 1] = div()
			:style(sty():row():wrel(1.0):h(controlHeight):align("center")):children(controlChildren)

		local main
		if stacked then
			main = div()
				:style(
					sty()
						:h(availableHeight):column():align("center"):justify("center"):gap(stackGap):pad(mainPad, 0, mainPad, 0)
				)
			main:children({
				coverFrame,
				div():style(sty():column():h(textHeight):gap(stageGap):w(progressWidth)):children(textRows)
			})
		else
			main = div()
				:style(sty():h(availableHeight):row():align("center"):justify("center"):gap(gap):pad(mainPad, 0, mainPad, 0))
			main:children({
				coverFrame,
				div():style(sty():column():h(stageHeight):justify("center"):gap(stageGap):w(progressWidth)):children(textRows)
			})
		end
		contentChildren[#contentChildren + 1] = main
	end
	contentChildren[#contentChildren + 1] = header

	-- The FFT belongs to the window, not to the padded content: the content's gutter only
	-- positions the controls, while the background bars run to every edge.
	local content = div()
		:style(sty():fill():column():pad(margin + topInset, margin, margin, margin):gap(theme:space(16))):children(contentChildren)

	local children = { spectrumBackground.view(app, { intensity = 0.7, reach = 0.8, bold = true }), content }
	-- The panels sit inside the stage, so what closes them on a click elsewhere is here: under
	-- them, over everything else on the screen.
	if app:overlay("queue") ~= nil or app:overlay("more") ~= nil then
		children[#children + 1] = div():style(sty():fill():offset(0, 0):z(128)):onClick({ type = "dismiss" })
	end

	return div():style(styles.screen):children(children)
end

return nowPlaying
