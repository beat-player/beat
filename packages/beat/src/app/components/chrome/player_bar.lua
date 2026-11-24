-- The bar along the bottom that follows the queue: the desktop one with transport, progress and
-- volume, and the phone's one row that opens the individual track view.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local cover = require("beat.app.components.cover")
local progress = require("beat.app.components.progress")
local spectrumBackground = require("beat.app.components.spectrum_background")
local tapButton = require("beat.app.components.tap_button")
local volume = require("beat.app.components.volume")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local playerBar = {}

---@class beat.components.chrome.PlayerBarProps
---@field width number # The window's width
---@field ui beat.ui.Context

--- The styles the desktop bar is built from, which depend on the theme and on the window's width
--- and on nothing else: they are kept on the theme for the width they were built for rather than
--- made again every frame the bar is in, which is every frame.
---@class beat.components.chrome.PlayerBarStyles
---@field width number
---@field progressWidth number
---@field volumeTrackWidth number
---@field empty wonderland.StyleBuilder
---@field controls wonderland.StyleBuilder
---@field play wonderland.StyleBuilder
---@field cards wonderland.StyleBuilder
---@field left wonderland.StyleBuilder
---@field info wonderland.StyleBuilder
---@field title wonderland.StyleBuilder
---@field artist wonderland.StyleBuilder
---@field right wonderland.StyleBuilder
---@field clocks wonderland.StyleBuilder
---@field bar wonderland.StyleBuilder
---@field row wonderland.StyleBuilder

---@param theme beat.Theme
---@param width number
---@return beat.components.chrome.PlayerBarStyles
local function barStyles(theme, width)
	---@type table<string, any>
	local cache = theme:cache()
	local styles = cache.playerBar --[[@as beat.components.chrome.PlayerBarStyles?]]
	if styles ~= nil and styles.width == width then return styles end

	local wide = width > 1180
	local progressWidth = wide ? (theme:px(240)) : (theme:px(160))
	local sideWidth = math.max(theme:px(280), progressWidth + theme:px(44))

	styles = {
		width = width,
		progressWidth = progressWidth,
		volumeTrackWidth = progressWidth - theme:px(34) * 2 - theme:px(8) * 2,
		empty = cache.playerBarEmpty or sty():h(0),
		controls = sty():row():align("center"):justify("center"):gap(theme:px(10)),
		play = sty()
			:size(theme:px(38), theme:px(38)):radius(theme:radius("full")):bg(theme:color("accent")):align("center")
			:justify("center"),
		cards = sty():row():w(wide and theme:px(300) or theme:px(220)):h("auto"):align("center"):justify("center"),
		left = sty():row():w(sideWidth):h("auto"):gap(theme:px(14)):align("center"),
		info = sty():w(210):h("auto"):column():justify("center"):gap(2),
		title = theme:s():w(210):text(theme:type("base")):weight("semibold"):fg(theme:color("text")):ellipsis(),
		artist = theme:s():w(210):text(theme:type("sm")):fg(theme:color("muted")):ellipsis(),
		right = sty():row():w(sideWidth):h("auto"):gap(theme:px(14)):align("center"):justify("end"),
		clocks = sty():column():w(progressWidth):h("auto"):justify("center"):align("end"):gap(theme:px(6)),
		bar = sty():row():wrel(1.0):h(theme:px(88)):bg(theme:color("surface")),
		row = sty()
			:row():wrel(1.0):hrel(1.0):pad(0, theme:px(16), 0, theme:px(16)):gap(theme:px(14)):align("center")
			:justify("space-between")
	}
	cache.playerBarEmpty = styles.empty
	cache.playerBar = styles

	return styles
end

---@param app beat.App
---@param props beat.components.chrome.PlayerBarProps
---@return wonderland.Element
function playerBar.view(app, props)
	local width = props.width
	local ctx = props.ui
	local theme = app.services.appearance.theme
	local styles = barStyles(theme, width)
	local track = app.services.playback:current()
	local player = app.services.playback.player
	if track == nil then return div():style(styles.empty) end

	local album = app.services.library.current and app.services.library.current:album(track.albumId)
	if album == nil then
		album = {
			id = 0,
			title = track.album,
			artist = track.artist,
			tracks = {},
			coverPath = track.coverPath,
			coverTrack = track
		}
	end
	local art = cover.view(app, { album = album, size = theme:px(56), radius = theme:radius("sm") })
	if album.id ~= 0 then
		art:onClick({ type = "navigate", page = { kind = "album", id = album.id } })
		art:onContextMenu(|_, _, _, _, _, windowX, windowY| -> {
			type = "open",
			overlay = "menu",
			menu = "album",
			id = album.id,
			x = windowX,
			y = windowY
		})
	end

	local isPlaying = player:isPlaying()
	local controls = div():style(styles.controls):children({
		ui.iconButton(ctx, {
			name = "shuffle",
			size = theme:px(28),
			onClick = { type = "shuffle" },
			active = player.queue?.shuffle ?? false
		}),
		ui.iconButton(ctx, { name = "previous", size = theme:px(28), onClick = { type = "previous" } }),
		div():style(styles.play):onClick({ type = "togglePlay" }):children(ui.icon(ctx, {
			name = isPlaying ? "pause" : "play",
			size = (theme:px(20)),
			colour = theme.accentInk
		})),
		ui.iconButton(ctx, { name = "next", size = theme:px(28), onClick = { type = "next" } }),
		ui.iconButton(ctx, {
			name = player.queue?.repeatMode == "one" ? "repeatOne" : "repeat",
			size = theme:px(28),
			onClick = { type = "repeat" },
			active = player.queue and player.queue.repeatMode ~= "off"
		})
	})

	local cards = div():style(styles.cards):children(controls)
	local progressWidth = styles.progressWidth

	local left = div():style(styles.left):children({
		art,
		div():style(styles.info):onClick(album.id ~= 0 ? { type = "navigate", page = { kind = "album", id = album.id } } : nil):children({
			text(track.title):style(styles.title),
			text(track.artist):style(styles.artist)
		})
	})
	local right = div():style(styles.right):children({
		div():style(styles.clocks):children({
			progress.view(app, { track = track, player = player, width = progressWidth }),
			volume.view(app, { width = progressWidth, trackWidth = styles.volumeTrackWidth, ui = ctx })
		}),
		ui.iconButton(ctx, { name = "chevronUp", size = theme:px(30), onClick = { type = "open", overlay = "now_playing" } })
	})

	return div():style(styles.bar):onMouseMove(function()
		if app.services.sidebar.hover ~= nil then return { type = "hoverPlaylist", id = nil } end
		return nil
	end):children({ spectrumBackground.view(app, {}), div():style(styles.row):children({ left, cards, right }) })
end

--- The phone bar's styles, kept for the same reason the desktop bar's are.
---@class beat.components.chrome.PlayerBarMobileStyles
---@field width number
---@field artSize number
---@field nextSize number
---@field nextHit number
---@field empty wonderland.StyleBuilder
---@field bar wonderland.StyleBuilder
---@field row wonderland.StyleBuilder
---@field info wonderland.StyleBuilder
---@field title wonderland.StyleBuilder
---@field artist wonderland.StyleBuilder
---@field play wonderland.StyleBuilder
---@field playHit wonderland.StyleBuilder
---@field lineHeight number
---@field line string
---@field played string

---@param theme beat.Theme
---@param width number
---@return beat.components.chrome.PlayerBarMobileStyles
local function mobileStyles(theme, width)
	---@type table<string, any>
	local cache = theme:cache()
	local styles = cache.playerBarMobile --[[@as beat.components.chrome.PlayerBarMobileStyles?]]
	if styles ~= nil and styles.width == width then return styles end

	local pad = theme:space(12)
	local artSize = theme:px(42)
	local playSize = theme:px(40)
	local nextSize = theme:px(32)
	-- A thumb needs more than a glyph: each control answers over a larger transparent box, and the
	-- text gets only what the boxes leave. The 56 box still fits the bar's 64.
	local playHit = math.max(playSize, theme:px(48))
	local nextHit = math.max(nextSize, theme:px(56))
	local gap = theme:space(10)
	local textWidth = math.max(theme:px(70), width - pad * 2 - artSize - playHit - nextHit - gap * 3)

	styles = {
		width = width,
		artSize = artSize,
		nextSize = nextSize,
		nextHit = nextHit,
		empty = cache.playerBarEmpty or sty():h(0),
		-- The bar's background is a box of its own so the meter, a layer behind the row, is not
		-- inset by the row's padding: the same shape as the desktop bar.
		bar = sty():row():wrel(1.0):h(theme:px(64)):bg(theme:color("surface")),
		row = sty():row():wrel(1.0):hrel(1.0):pad(0, pad, 0, pad):gap(gap):align("center"),
		info = sty():column():w(textWidth):hrel(1.0):justify("center"):gap(1),
		title = theme:s():w(textWidth):text(theme:type("sm")):weight("semibold"):fg(theme:color("text")):ellipsis(),
		artist = theme:s():w(textWidth):text(theme:type("xs")):fg(theme:color("muted")):ellipsis(),
		play = sty()
			:size(playSize, playSize):radius(theme:radius("full")):bg(theme:color("accent")):align("center"):justify("center"),
		-- The transparent box the play control's circle is centred in, so the circle stays 40 and
		-- the target under it is 48.
		playHit = sty():size(playHit, playHit):align("center"):justify("center"),
		-- The two colours of the strip of playhead at the bottom, and the height of it.
		lineHeight = math.max(2, theme:px(2)),
		line = theme:color("text", 0.1),
		played = theme:color("accent")
	}
	cache.playerBarEmpty = styles.empty
	cache.playerBarMobile = styles

	return styles
end

--- The phone mini player: one row above the bottom tabs, over the same spectrum the desktop bar
--- draws. The whole row opens the individual track view; the play and next controls inside it
--- keep their own actions.
---@param app beat.App
---@param props beat.components.chrome.PlayerBarProps
---@return wonderland.Element
function playerBar.mobile(app, props)
	local width = props.width
	local ctx = props.ui
	local theme = app.services.appearance.theme
	local styles = mobileStyles(theme, width)
	local track = app.services.playback:current()
	local playing = app.services.playback.player:isPlaying()
	if track == nil then return div():style(styles.empty) end

	local album = app.services.library.current and app.services.library.current:album(track.albumId)
	if album == nil then
		album = {
			id = 0,
			title = track.album,
			artist = track.artist,
			tracks = {},
			coverPath = track.coverPath,
			coverTrack = track
		}
	end

	local playback = app.services.playback

	local row = div():style(styles.row):canvas(function(canvas)
		-- The place in the track is read when the strip is drawn, not when the view was built: a
		-- repaint moves it without the row being laid out again.
		local duration = track.duration > 0 and track.duration or playback.player:duration()
		local position = playback.player:position()
		local fraction = duration > 0 ? math.max(0, math.min(1, position / duration)) : 0
		local line = styles.lineHeight

		canvas:rect(0, canvas.height - line, canvas.width, line, styles.line)
		if fraction > 0 then
			canvas:rect(0, canvas.height - line, math.floor(canvas.width * fraction), line, styles.played)
		end
	end):children({
		cover.view(app, { album = album, size = styles.artSize, radius = theme:radius("sm") }),
		div():style(styles.info):children({ text(track.title):style(styles.title), text(track.artist):style(styles.artist) }),
		div():style(styles.playHit):onClick({ type = "togglePlay" }):children({
			div():style(styles.play):children(ui.icon(ctx, {
				name = playing ? "pause" : "play",
				size = (theme:px(19)),
				colour = theme.accentInk
			}))
		}),
		tapButton.view(ctx, { name = "next", size = styles.nextSize, hit = styles.nextHit, onClick = { type = "next" } })
	})

	-- The meter is the desktop bar's own, put behind the row: it reads the levels when the frame
	-- is drawn, so the app's repaints move it while the music plays and leave it still once it stops.
	-- The bar answers a press itself, but a press in one of the controls meets that control first:
	-- the enlarged boxes take their presses without the track view opening under them.
	return div():style(styles.bar):onClick({ type = "open", overlay = "now_playing" }):children({
		spectrumBackground.view(app, {}),
		row
	})
end

return playerBar
