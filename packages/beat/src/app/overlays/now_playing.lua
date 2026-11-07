-- The playing track as the whole screen: the cover, the controls and the panels that open from
-- them. It is opened over the page rather than replacing it, so what is left of the app stays
-- underneath while a transition runs.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local iconButton = require("beat.app.components.icon_button")
local cover = require("beat.app.components.cover")
local playingBars = require("beat.app.components.playing_bars")
local progress = require("beat.app.components.progress")
local spectrumBackground = require("beat.app.components.spectrum_background")
local metrics = require("beat.app.components.helpers.metrics")
local surfaces = require("beat.app.surfaces")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

--- The volume control is a button. Its bubble is a sibling of the transport group rather than a
--- child of the button: a positioned panel inside a size-locked button shifted the row's paint
--- order on short windows, clipping the play control.
---@param app beat.App
---@param size number
---@return wonderland.Element
local function volumeButton(app, size)
	local muted = app.services.settings.values.isMuted
	return iconButton.view(app, {
		name = muted and "mute" or "volume",
		size = size,
		onClick = { type = "toggleVolume"},
		active = app:overlay("volume") ~= nil,
	})
end

--- Three dots, drawn rather than taken from the icon face: the face has no ellipsis, and a
--- text fallback would sit on the wrong baseline next to the other controls.
---@param app beat.App
---@param size number
---@param onClick any
---@param active boolean?
---@return wonderland.Element
local function moreButton(app, size, onClick, active)
	local theme = app.services.appearance.theme
	local colour = active and theme:color("text") or theme:color("muted")

	return iconButton.surface(app, {
		size = size,
		onClick = onClick,
		content = div():style(sty():size(size, size)):canvas(function(canvas)
			local radius = math.max(1.2, math.floor(size * 0.064))
			local y = math.floor(canvas.height / 2 - radius)
			for at = 0, 2 do
				local x = math.floor(canvas.width / 2 + (at - 1) * size * 0.21 - radius)
				canvas:rect(x, y, radius * 2, radius * 2, colour, radius)
			end
		end),
	})
end

--- The equalizer has no behaviour yet, so this is only its mark: four static bars, quieter than
--- the playing indicator because nothing here is measuring audio.
---@param app beat.App
---@param size number
---@param onClick any
---@param active boolean?
---@return wonderland.Element
local function equalizerButton(app, size, onClick, active)
	local theme = app.services.appearance.theme
	local colour = active and theme:color("text") or theme:color("muted")
	local inner = math.max(12, math.floor(size * 0.72 + 0.5))

	return iconButton.surface(app, {
		size = size,
		onClick = onClick,
		content = div():style(sty():size(inner, inner)):canvas(function(canvas)
			local levels = { 0.36, 0.7, 0.48, 0.58}
			local barWidth = math.max(2, math.floor(inner * 0.1))
			local gap = math.max(2, math.floor((canvas.width - barWidth * #levels) / (#levels + 1)))
			for at, level in ipairs(levels) do
				local height = math.max(2, math.floor(canvas.height * level))
				local x = math.floor(gap + (at - 1) * (barWidth + gap))
				canvas:rect(x, canvas.height - height, barWidth, height, colour, barWidth / 2)
			end
		end),
	})
end

---@class beat.ToolRoom
---@field below number # How far the window goes under the now-playing tool row
---@field above number # And over it
---@field top number # Where the tool row's top is from the top of the box a panel is offset from

--- Places a panel opened from the now-playing tool row: under the row where it fits or where
--- there is more room below than above, over it otherwise.
---@param app beat.App
---@param panel wonderland.Element
---@param x number # From the row's left edge
---@param width number
---@param height number
---@param room beat.ToolRoom
---@return wonderland.Element
local function toolPanel(app, panel, x, width, height, room)
	local theme = app.services.appearance.theme
	local gap = theme:px(6)
	local below = height + gap <= room.below or room.below >= room.above
	local y = room.top + (below and (theme:px(34) + gap) or -(height + gap))
	return div():style(sty():w(width):h(height):offset(x, y):z(130)):children({ panel})
end

--- Draws a panel at the button that opened it. The anchor -- where the controls row is, and how
--- much room there is on either side of it -- is this screen's to work out: the panel only knows
--- how big it is.
---@param app beat.App
---@param name string
---@param anchor table
---@param window wonderland.RenderWindow
---@return wonderland.Element?
local function anchored(app, name, anchor, window)
	local overlay = app:overlay(name)
	if overlay == nil then return nil end
	overlay.state.anchor = anchor
	return surfaces.overlay(name).view(app, overlay, window)
end

---@class beat.NowPlayingOverlay: beat.OverlaySurface
---@field toolPanel fun(app: beat.App, panel: wonderland.Element, x: number, width: number, height: number, room: beat.ToolRoom): wonderland.Element

---@type beat.NowPlayingOverlay
local nowPlaying = { fullscreen = true}

nowPlaying.toolPanel = toolPanel

function nowPlaying.new(app)
	app.services.motion.clock:animate("nowPlaying", 1, 0.28, ui.motion.ease.outBack)
	return {}
end

---@param app beat.App
---@param _overlay beat.OverlayInstance
function nowPlaying.close(app, _overlay)
	app.services.motion.clock:animate("nowPlaying", 0, 0.28, ui.motion.ease.inCubic)
end

function nowPlaying.update(app, overlay, message)
	local kind = message.type
	if kind == "expandNowPlaying" then
		-- The screen's own chevron. It closes this screen and every panel opened from it, not just
		-- whichever panel happens to be on top.
		if message.open ~= true then app:close(overlay) end
	elseif kind == "toggleVolume" then
		app:open("volume")
	elseif kind == "toggleQueue" then
		app:open("queue")
	elseif kind == "toggleMore" then
		app:open("more")
	elseif kind == "toggleEqualizer" then
		app:open("equalizer")
	else
		return false
	end
	return true
end

---@param app beat.App
---@param _overlay beat.OverlayInstance
---@param window wonderland.RenderWindow
---@return wonderland.Element
function nowPlaying.view(app, _overlay, window)
	local theme = app.services.appearance.theme
	local mobile = metrics.mobile(app, window.width)
	local stacked = mobile and window.height >= theme:px(560)
	local track = app.services.playback:current()
	---@type beat.Album?
	local album
	local library = app.services.library
	if track ~= nil and library.current ~= nil then album = library.current:album(track.albumId) end
	local margin = mobile and theme:space(16)
	or math.max(theme:space(10), math.min(theme:space(28),
	math.floor(window.width * 0.03), math.floor(window.height * 0.03)))
	local availableWidth = window.width - margin * 2
	local availableHeight = window.height - margin * 2
	local mainPad = math.min(theme:space(32), math.max(theme:px(12), math.floor(availableHeight * 0.06)))
	local gap = theme:space(32)
	local desiredProgress = window.width >= 1240 and theme:px(600) or theme:px(380)
	local compact = availableHeight < theme:px(430)
	local stageGap = compact and theme:px(6) or theme:px(10)

	local header = div():style(sty():row():wrel(1.0):h(theme:px(36)):justify("end")
	:align("center"):offset(0, 0):z(110)):children({
	iconButton.view(app, {
	name = "chevronDown",
	size = theme:px(34),
	onClick = { type = "expandNowPlaying", open = false},
	}),
	})
	local contentChildren = {}

	if track ~= nil and album ~= nil then
		---@cast track beat.Track
		---@cast album beat.Album
		local coverSize
		local progressWidth
		if stacked then
			coverSize = math.min(theme:px(220), math.floor(availableWidth * 0.58),
			math.floor(availableHeight * 0.34))
			progressWidth = math.max(theme:px(160), availableWidth - mainPad * 2)
		else
			coverSize = math.min(theme:px(390), math.floor(availableWidth * 0.27),
			math.floor(availableHeight * 0.43))
			local maxText = availableWidth - coverSize - gap
			if maxText < theme:px(180) then
				coverSize = math.max(theme:px(64), availableWidth - gap - theme:px(180))
				maxText = availableWidth - coverSize - gap
			end
			progressWidth = math.max(theme:px(160), math.min(desiredProgress, maxText))
		end
		local stageHeight = math.min(theme:px(340), math.max(theme:px(220),
		availableHeight - theme:px(34) - mainPad * 2))

		local coverFrame = div():style(sty():size(coverSize, coverSize):shadow(0, 12, 20, "#00000060"))
		:onClick({ type = "navigate", page = { kind = "album", id = album.id}})
		:onContextMenu(function(_, _, _, _, _, windowX, windowY)
			return { type = "open", overlay = "album_menu", id = album.id, x = windowX, y = windowY}
		end)
		:children(cover.view(app, { album = album, size = coverSize, radius = theme:radius("lg"), glow = true }))
		local transport = math.max(0.7, math.min(1, progressWidth / theme:px(240)))
		local controlGap = theme:px(10 * transport)
		local textRows = {
		text(track.title):style(theme:s():w(progressWidth)
		:text(theme:type(mobile and "xxl" or "hero")):weight("bold")
		:fg(theme:color("text")):ellipsis()),
		text(album.title .. "  ·  " .. track.artist):style(theme:s():w(progressWidth)
		:text(theme:type("lg")):weight("medium"):fg(theme:color("muted")):ellipsis()),
		}
		local repeatIcon = app.services.playback.player.queue and app.services.playback.player.queue.repeatMode == "one"
		and "repeatOne" or "repeat"
		local repeatActive = app.services.playback.player.queue and app.services.playback.player.queue.repeatMode ~= "off"
		local toolSize = theme:px(28)
		local toolGap = theme:px(4)
		local toolGroupWidth = toolSize * 2 + toolGap
		textRows[#textRows + 1] = div():style(sty():row():wrel(1.0):h(theme:px(34))
		:align("center"):justify("space-between")):children({
		div():style(sty():row():w(toolGroupWidth):h(theme:px(34)):gap(toolGap)
		:align("center")):children({
		iconButton.view(app, {
		name = "playlists",
		size = toolSize,
		onClick = { type = "toggleQueue"},
		active = app:overlay("queue") ~= nil,
		}),
		moreButton(app, toolSize, { type = "toggleMore"}, app:overlay("more") ~= nil),
		}),
		div():style(sty():row():w(toolGroupWidth):h(theme:px(34)):gap(toolGap)
		:align("center")):children({
		iconButton.view(app, {
		name = "shuffle",
		size = toolSize,
		onClick = { type = "shuffle"},
		active = app.services.playback.player.queue and app.services.playback.player.queue.shuffle,
		}),
		iconButton.view(app, {
		name = repeatIcon,
		size = toolSize,
		onClick = { type = "repeat"},
		active = repeatActive,
		}),
		})
		})
		textRows[#textRows + 1] = progress.view(app, {
		track = track,
		player = app.services.playback.player,
		width = progressWidth,
		})
		local controlHeight = theme:px(54 * transport)
		-- The transport is centred by a spacer either side rather than by spreading the row: the
		-- panels below are boxes offset from the row, and a spread row still counts them among the
		-- boxes it spreads, which moved the transport towards them. The spacers share what the
		-- other boxes leave, so the transport says how wide it is.
		local skipSize = theme:px(30 * transport)
		local playSize = theme:px(54 * transport)
		local controlChildren = {
		volumeButton(app, theme:px(28 * transport)),
		div():style(sty():w("auto"):h(controlHeight)),
		div():style(sty():row():w(skipSize * 2 + playSize + controlGap * 2):h(controlHeight)
		:gap(controlGap):align("center"):justify("center")):children({
		iconButton.view(app, { name = "previous", size = skipSize, onClick = { type = "previous"} }),
		div():style(sty():size(playSize, playSize)
		:radius(theme:radius("full")):bg(theme:color("accent"))
		:align("center"):justify("center"))
		:onClick({ type = "togglePlay"})
		:children(ui.icons.element(app.services.playback.player:isPlaying() and "pause" or "play",
		theme:px(24 * transport), theme.accentInk)),
		iconButton.view(app, { name = "next", size = skipSize, onClick = { type = "next"} }),
		}),
		div():style(sty():w("auto"):h(controlHeight)),
		equalizerButton(app, theme:px(28 * transport),
		{ type = "toggleEqualizer"}, app:overlay("equalizer") ~= nil),
		}
		local panelHeight = theme:px(44)
		local volumePanel = anchored(app, "volume", {
		width = theme:px(190),
		height = panelHeight,
		x = 0,
		y = compact and (-panelHeight - theme:px(8)) or (controlHeight + theme:px(8)),
		}, window)
		if volumePanel ~= nil then controlChildren[#controlChildren + 1] = volumePanel end
		local titleSize = theme:type(mobile and "xxl" or "hero")
		local textHeight = titleSize + theme:type("lg") + theme:px(34 + 18) + controlHeight + stageGap * 4

		-- The queue and the menu open from the tool row, towards whichever side of it has the room.
		-- Where the row is comes from the sizes the stage is centred with -- a line of text is as
		-- tall as its type -- so the panels can be sized before the layout has run.
		local lead = stacked and (coverSize + theme:space(16)) or 0
		local rowTop = margin + mainPad + (availableHeight - mainPad * 2 - lead - textHeight) / 2 + lead
		+titleSize + theme:type("lg") + stageGap * 2
		local edge = theme:px(12)
		-- They are offset from the controls, the last row of the stage, rather than from the tool
		-- row: what is painted later than a panel and under its shadow is not painted at all, and
		-- nothing in the stage is painted later than its last row. The tool row is a fixed distance
		-- above it.
		local room = {
		below = window.height - edge - rowTop - theme:px(34),
		above = rowTop - edge,
		top = -(theme:px(34) + theme:px(18) + stageGap * 2),
		}
		local queuePanel = anchored(app, "queue", {
		toolWidth = progressWidth,
		room = room,
		}, window)
		if queuePanel ~= nil then controlChildren[#controlChildren + 1] = queuePanel end
		local menu = anchored(app, "more", {
		rowWidth = progressWidth,
		room = room,
		x = toolSize + toolGap,
		}, window)
		if menu ~= nil then controlChildren[#controlChildren + 1] = menu end
		textRows[#textRows + 1] = div():style(sty():row():wrel(1.0):h(controlHeight)
		:align("center")):children(controlChildren)

		local main
		if stacked then
			main = div():style(sty():h(availableHeight)
			:column():align("center"):justify("center"):gap(theme:space(16)):pad(mainPad, 0, mainPad, 0))
			main:children({
			coverFrame,
			div():style(sty():column():h(textHeight):gap(stageGap)
			:w(progressWidth)):children(textRows),
			})
		else
			main = div():style(sty():h(availableHeight)
			:row():align("center"):justify("center"):gap(gap):pad(mainPad, 0, mainPad, 0))
			main:children({
			coverFrame,
			div():style(sty():column():h(stageHeight):justify("center"):gap(stageGap)
			:w(progressWidth)):children(textRows),
			})
		end
		contentChildren[#contentChildren + 1] = main
	end
	contentChildren[#contentChildren + 1] = header

	-- The FFT belongs to the window, not to the padded content: the content's gutter only
	-- positions the controls, while the background bars run to every edge.
	local content = div():style(sty():fill():column():pad(margin, margin, margin, margin)
	:gap(theme:space(16))):children(contentChildren)

	local children = { spectrumBackground.view(app, { intensity = 0.28, reach = 0.72 }), content}
	-- The panels sit inside the stage, so what closes them on a click elsewhere is here: under
	-- them, over everything else on the screen.
	if app:overlay("queue") ~= nil or app:overlay("more") ~= nil then
		children[#children + 1] = div():style(sty():fill():offset(0, 0):z(128))
		:onClick({ type = "dismiss"})
	end

	return div()
	:style(sty():fill():offset(0, 0):z(100):column():bg(theme:color("bg"))
	:fg(theme:color("text")):font(theme.fontFamily))
	:children(children)
end

return nowPlaying
