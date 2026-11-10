-- The playing track as the whole screen: the cover, the controls and the panels that open from
-- them. It is opened over the page rather than replacing it, so what is left of the app stays
-- underneath while a transition runs.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local cover = require("beat.app.components.cover")
local progress = require("beat.app.components.progress")
local spectrumBackground = require("beat.app.components.spectrum_background")
local metrics = require("beat.app.components.helpers.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

--- The volume control is a button. Its bubble is a sibling of the transport group rather than a
--- child of the button: a positioned panel inside a size-locked button shifted the row's paint
--- order on short windows, clipping the play control.
---@param app beat.App
---@param ctx beat.ui.Context
---@param size number
local function volumeButton(app, ctx, size)
	local muted = app.services.settings.values.isMuted
	return ui.iconButton(
		ctx,
		{
			name = muted ? "mute" : "volume",
			size = size,
			onClick = { type = "toggleVolume" },
			active = app:overlay("volume") ~= nil
		}
	)
end

--- Three dots, drawn rather than taken from the icon face: the face has no ellipsis, and a
--- text fallback would sit on the wrong baseline next to the other controls.
---@param app beat.App
---@param ctx beat.ui.Context
---@param size number
---@param onClick any
---@param active boolean?
local function moreButton(app, ctx, size, onClick, active)
	local theme = app.services.appearance.theme
	local colour = active ? (theme:color("text")) : (theme:color("muted"))

	return ui.iconButton(ctx, { size = size, onClick = onClick, content = div():style(sty():size(size, size)):canvas(function(canvas)
		local radius = math.max(1.2, math.floor(size * 0.064))
		local y = math.floor(canvas.height / 2 - radius)
		for at = 0, 2 do
			local x = math.floor(canvas.width / 2 + (at - 1) * size * 0.21 - radius)
			canvas:rect(x, y, radius * 2, radius * 2, colour, radius)
		end
	end) })
end

--- The equalizer has no behaviour yet, so this is only its mark: four static bars, quieter than
--- the playing indicator because nothing here is measuring audio.
---@param app beat.App
---@param ctx beat.ui.Context
---@param size number
---@param onClick any
---@param active boolean?
local function equalizerButton(app, ctx, size, onClick, active)
	local theme = app.services.appearance.theme
	local colour = active ? (theme:color("text")) : (theme:color("muted"))
	local inner = math.max(12, math.floor(size * 0.72 + 0.5))

	return ui.iconButton(ctx, { size = size, onClick = onClick, content = div():style(sty():size(inner, inner)):canvas(function(canvas)
		local levels = { 0.36, 0.7, 0.48, 0.58 }
		local barWidth = math.max(2, math.floor(inner * 0.1))
		local gap = math.max(2, math.floor((canvas.width - barWidth * #levels) / (#levels + 1)))
		for at, level in ipairs(levels) do
			local height = math.max(2, math.floor(canvas.height * level))
			local x = math.floor(gap + (at - 1) * (barWidth + gap))
			canvas:rect(x, canvas.height - height, barWidth, height, colour, barWidth / 2)
		end
	end) })
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
	return div():style(sty():w(width):h(height):offset(x, y):z(130)):children({ panel })
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
---@field toolPanel fun(app: beat.App, panel: wonderland.Element, x: number, width: number, height: number, room: beat.ToolRoom): wonderland.Element

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
	local availableHeight = window.height - margin * 2
	local mainPad = math.min(theme:space(32), math.max(theme:px(12), math.floor(availableHeight * 0.06)))
	local gap = theme:space(32)
	local desiredProgress = window.width >= 1240 ? (theme:px(600)) : (theme:px(380))
	local compact = availableHeight < theme:px(430)
	local stageGap = compact ? (theme:px(6)) : (theme:px(10))

	local header = div()
		:style(sty():row():wrel(1.0):h(theme:px(36)):justify("end"):align("center"):offset(0, 0):z(110))
		:children(
			{
				ui.iconButton(
					ctx,
					{ name = "chevronDown", size = theme:px(34), onClick = { type = "expandNowPlaying", open = false } }
				)
			}
		)
	local contentChildren = {}

	if track ~= nil and album ~= nil then
		local coverSize
		local progressWidth
		if stacked then
			coverSize = math.min(theme:px(220), math.floor(availableWidth * 0.58), math.floor(availableHeight * 0.34))
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
		local stageHeight = math.min(theme:px(340), math.max(theme:px(220), availableHeight - theme:px(34) - mainPad * 2))

		local coverFrame = div()
			:style(sty():size(coverSize, coverSize):shadow(0, 12, 20, "#00000060"))
			:onClick({ type = "navigate", page = { kind = "album", id = album.id } })
			:onContextMenu(
				|_, _, _, _, _, windowX, windowY| -> {
					type = "open",
					overlay = "menu",
					menu = "album",
					id = album.id,
					x = windowX,
					y = windowY
				}
			):children(cover.view(app, { album = album, size = coverSize, radius = theme:radius("lg"), glow = true }))
		local transport = math.max(0.7, math.min(1, progressWidth / theme:px(240)))
		local controlGap = theme:px(10 * transport)
		local textRows = {
			text(track.title)
				:style(
					theme:s()
						:w(progressWidth):text(((theme:type(mobile ? "xxl" : "hero")))):weight("bold"):fg(theme:color("text")):ellipsis()
				),
			text(album.title .. "  ·  " .. track.artist)
				:style(theme:s():w(progressWidth):text(theme:type("lg")):weight("medium"):fg(theme:color("muted")):ellipsis())
		}
		local queue = app.services.playback.player.queue
		local repeatIcon = queue?.repeatMode == "one" ? "repeatOne" : "repeat"
		local repeatActive = queue ~= nil and queue.repeatMode ~= "off"
		local toolSize = theme:px(28)
		local toolGap = theme:px(4)
		local toolGroupWidth = toolSize * 2 + toolGap
		local toolChildren = {
			div()
				:style(sty():row():w(toolGroupWidth):h(theme:px(34)):gap(toolGap):align("center"))
				:children(
					{
						ui.iconButton(
							ctx,
							{
								name = "playlists",
								size = toolSize,
								onClick = { type = "toggleQueue" },
								active = app:overlay("queue") ~= nil
							}
						),
						moreButton(app, ctx, toolSize, { type = "toggleMore" }, app:overlay("more") ~= nil)
					}
				)
		}
		-- The rating sits between the two groups where the row has room for it; a narrow stage
		-- still has it at the top of the three dots' menu.
		local starSize = theme:px(16)
		local starGap = theme:px(2)
		if progressWidth - toolGroupWidth * 2 >= starSize * 5 + starGap * 4 + theme:px(24) then
			toolChildren[#toolChildren + 1] = ui.rating(
				ctx,
				{
					value = app.services.collections.taxonomy:rating(track.path),
					onRate = |stars| -> { type = "rateTrack", id = track.id, stars = stars },
					size = starSize,
					gap = starGap
				}
			)
		end
		toolChildren[#toolChildren + 1] = div()
			:style(sty():row():w(toolGroupWidth):h(theme:px(34)):gap(toolGap):align("center"))
			:children(
				{
					ui.iconButton(
						ctx,
						{ name = "shuffle", size = toolSize, onClick = { type = "shuffle" }, active = queue?.shuffle ?? false }
					),
					ui.iconButton(
						ctx,
						{ name = repeatIcon, size = toolSize, onClick = { type = "repeat" }, active = repeatActive }
					)
				}
			)
		textRows[#textRows + 1] = div()
			:style(sty():row():wrel(1.0):h(theme:px(34)):align("center"):justify("space-between"))
			:children(toolChildren)
		textRows[#textRows + 1] = progress.view(
			app,
			{ track = track, player = app.services.playback.player, width = progressWidth }
		)
		local controlHeight = theme:px(54 * transport)
		-- The transport is centred by a spacer either side rather than by spreading the row: the
		-- panels below are boxes offset from the row, and a spread row still counts them among the
		-- boxes it spreads, which moved the transport towards them. The spacers share what the
		-- other boxes leave, so the transport says how wide it is.
		local skipSize = theme:px(30 * transport)
		local playSize = theme:px(54 * transport)
		local controlChildren = {
			volumeButton(app, ctx, theme:px(28 * transport)),
			div():style(sty():w("auto"):h(controlHeight)),
			div()
				:style(
					sty()
						:row():w(skipSize * 2 + playSize + controlGap * 2):h(controlHeight):gap(controlGap):align("center")
						:justify("center")
				)
				:children(
					{
						ui.iconButton(ctx, { name = "previous", size = skipSize, onClick = { type = "previous" } }),
						div()
							:style(
								sty()
									:size(playSize, playSize):radius(theme:radius("full")):bg(theme:color("accent")):align("center")
									:justify("center")
							):onClick({ type = "togglePlay" })
							:children(
								ui.icon(
									ctx,
									{
										name = (app.services.playback.player:isPlaying()) ? "pause" : "play",
										size = theme:px(24 * transport),
										colour = theme.accentInk
									}
								)
							),
						ui.iconButton(ctx, { name = "next", size = skipSize, onClick = { type = "next" } })
					}
				),
			div():style(sty():w("auto"):h(controlHeight)),
			equalizerButton(app, ctx, theme:px(28 * transport), { type = "toggleEqualizer" }, app:overlay("equalizer") ~= nil)
		}
		local panelHeight = theme:px(44)
		local volumePanel = anchored(
			app,
			"volume",
			{
				width = theme:px(190),
				height = panelHeight,
				x = 0,
				y = compact and (-panelHeight - theme:px(8)) or (controlHeight + theme:px(8))
			},
			window
		)
		if volumePanel ~= nil then controlChildren[#controlChildren + 1] = volumePanel end
		local titleSize = (theme:type(mobile ? "xxl" : "hero"))
		local textHeight = titleSize + theme:type("lg") + theme:px(34 + 18) + controlHeight + stageGap * 4

		-- The queue and the menu open from the tool row, towards whichever side of it has the room.
		-- Where the row is comes from the sizes the stage is centred with -- a line of text is as
		-- tall as its type -- so the panels can be sized before the layout has run.
		local lead = stacked and (coverSize + theme:space(16)) or 0
		local rowTop = margin + mainPad + (availableHeight - mainPad * 2 - lead - textHeight) / 2 + lead + titleSize + theme:type(
			"lg"
		) + stageGap * 2
		local edge = theme:px(12)
		-- They are offset from the controls, the last row of the stage, rather than from the tool
		-- row: what is painted later than a panel and under its shadow is not painted at all, and
		-- nothing in the stage is painted later than its last row. The tool row is a fixed distance
		-- above it.
		local room = {
			below = window.height - edge - rowTop - theme:px(34),
			above = rowTop - edge,
			top = -(theme:px(34) + theme:px(18) + stageGap * 2)
		}
		local queuePanel = anchored(app, "queue", { toolWidth = progressWidth, room = room }, window)
		if queuePanel ~= nil then controlChildren[#controlChildren + 1] = queuePanel end
		local menu = anchored(app, "more", { rowWidth = progressWidth, room = room, x = toolSize + toolGap }, window)
		if menu ~= nil then controlChildren[#controlChildren + 1] = menu end
		textRows[#textRows + 1] = div()
			:style(sty():row():wrel(1.0):h(controlHeight):align("center")):children(controlChildren)

		local main
		if stacked then
			main = div()
				:style(
					sty()
						:h(availableHeight):column():align("center"):justify("center"):gap(theme:space(16)):pad(mainPad, 0, mainPad, 0)
				)
			main:children(
				{ coverFrame, div():style(sty():column():h(textHeight):gap(stageGap):w(progressWidth)):children(textRows) }
			)
		else
			main = div()
				:style(sty():h(availableHeight):row():align("center"):justify("center"):gap(gap):pad(mainPad, 0, mainPad, 0))
			main:children(
				{
					coverFrame,
					div():style(sty():column():h(stageHeight):justify("center"):gap(stageGap):w(progressWidth)):children(textRows)
				}
			)
		end
		contentChildren[#contentChildren + 1] = main
	end
	contentChildren[#contentChildren + 1] = header

	-- The FFT belongs to the window, not to the padded content: the content's gutter only
	-- positions the controls, while the background bars run to every edge.
	local content = div()
		:style(sty():fill():column():pad(margin, margin, margin, margin):gap(theme:space(16))):children(contentChildren)

	local children = { spectrumBackground.view(app, { intensity = 0.28, reach = 0.72 }), content }
	-- The panels sit inside the stage, so what closes them on a click elsewhere is here: under
	-- them, over everything else on the screen.
	if app:overlay("queue") ~= nil or app:overlay("more") ~= nil then
		children[#children + 1] = div():style(sty():fill():offset(0, 0):z(128)):onClick({ type = "dismiss" })
	end

	return div()
		:style(sty():fill():offset(0, 0):z(100):column():bg(theme:color("bg")):fg(theme:color("text")):font(theme.fontFamily))
		:children(children)
end

return nowPlaying
