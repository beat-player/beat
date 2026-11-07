-- The bar along the bottom that follows the queue: the desktop one with transport, progress and
-- volume, and the phone's one row that opens the individual track view.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local render = require("beat.app.ui")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local playerBar = {}

---@param app beat.App
---@param width number
---@return wonderland.Element
function playerBar.view(app, width)
	local theme = app.services.appearance.theme
	local track = app.services.playback:current()
	local player = app.services.playback.player
	local height = theme:px(88)
	if track == nil then return div():style(sty():h(0)) end

	local album = app.services.library.current and app.services.library.current:album(track.albumId)
	if album == nil then
		album = {
		id = 0,
		title = track.album,
		artist = track.artist,
		tracks = {},
		coverPath = track.coverPath,
		coverTrack = track,
		}
	end
	---@cast track beat.Track
	---@cast album beat.Album
	local cover = render.cover(app, album, theme:px(56), theme:radius("sm"))
	if album.id ~= 0 then
		cover:onClick({ type = "navigate", page = { kind = "album", id = album.id}})
		cover:onContextMenu(function(_, _, _, _, _, windowX, windowY)
			return { type = "open", overlay = "album_menu", id = album.id, x = windowX, y = windowY}
		end)
	end

	local isPlaying = player:isPlaying()
	local controls = div():style(sty():row():align("center"):justify("center"):gap(theme:px(10))):children({
	render.iconButton(app, "shuffle", theme:px(28), { type = "shuffle"}, player.queue
	and player.queue.shuffle),
	render.iconButton(app, "previous", theme:px(28), { type = "previous"}),
	div():style(sty():size(theme:px(38), theme:px(38)):radius(theme:radius("full")):bg(theme:color("accent"))
	:align("center"):justify("center")):onClick({ type = "togglePlay"})
	:children(ui.icons.element(isPlaying and "pause" or "play", theme:px(20), theme.accentInk)),
	render.iconButton(app, "next", theme:px(28), { type = "next"}),
	render.iconButton(app, player.queue and player.queue.repeatMode == "one" and "repeatOne" or "repeat",
	theme:px(28), { type = "repeat"}, player.queue and player.queue.repeatMode ~= "off"),
	})

	local cards = div():style(sty():row():w(width > 1180 and theme:px(300) or theme:px(220)):h("auto")
	:align("center"):justify("center")):children(controls)
	local progressWidth = width > 1180 and theme:px(240) or theme:px(160)

	local sideWidth = math.max(theme:px(280), progressWidth + theme:px(44))
	local left = div():style(sty():row():w(sideWidth):h("auto"):gap(theme:px(14)):align("center"))
	:children({
	cover,
	div():style(sty():w(210):h("auto"):column():justify("center"):gap(2))
	:onClick(album.id ~= 0 and { type = "navigate", page = { kind = "album", id = album.id}} or nil)
	:children({
	text(track.title):style(theme:s():w(210):text(theme:type("base")):weight("semibold")
	:fg(theme:color("text")):ellipsis()),
	text(track.artist):style(theme:s():w(210):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()),
	}),
	})
	local right = div():style(sty():row():w(sideWidth):h("auto"):gap(theme:px(14)):align("center")
	:justify("end")):children({
	div():style(sty():column():w(progressWidth):h("auto"):justify("center"):align("end")
	:gap(theme:px(6))):children({
	render.progress(app, track, player, progressWidth),
	render.volume(app, progressWidth, progressWidth - theme:px(34) * 2 - theme:px(8) * 2),
	}),
	render.iconButton(app, "chevronUp", theme:px(30), { type = "open", overlay = "now_playing"}),
	})

	return div()
	:style(sty():row():wrel(1.0):h(height):bg(theme:color("surface")))
	:onMouseMove(function()
		if app.services.sidebar.hover ~= nil then return { type = "hoverPlaylist", id = nil} end
		return nil
	end)
	:canvas(function(canvas) render.spectrumBackground(app, canvas) end)
	:children({
	div():style(sty():row():wrel(1.0):hrel(1.0):pad(0, theme:px(16), 0, theme:px(16))
	:gap(theme:px(14)):align("center"):justify("space-between")):children({ left, cards, right}),
	})
end

--- The phone mini player: one row above the bottom tabs. The whole row opens the individual
--- track view; the play and next controls inside it keep their own actions.
---@param app beat.App
---@param width number
---@return wonderland.Element
function playerBar.mobile(app, width)
	local theme = app.services.appearance.theme
	local track = app.services.playback:current()
	local height = theme:px(64)
	if track == nil then return div():style(sty():h(0)) end

	local album = app.services.library.current and app.services.library.current:album(track.albumId)
	if album == nil then
		album = {
		id = 0,
		title = track.album,
		artist = track.artist,
		tracks = {},
		coverPath = track.coverPath,
		coverTrack = track,
		}
	end
	---@cast track beat.Track
	---@cast album beat.Album

	local pad = theme:space(12)
	local art = theme:px(42)
	local playSize = theme:px(40)
	local nextSize = theme:px(32)
	local gap = theme:space(10)
	local textWidth = width - pad * 2 - art - playSize - nextSize - gap * 3
	local playing = app.services.playback.player:isPlaying()
	local duration = track.duration > 0 and track.duration or app.services.playback.player:duration()
	local position = app.services.playback.player:position()
	local fraction = duration > 0 and math.max(0, math.min(1, position / duration)) or 0

	return div()
	:style(sty():row():wrel(1.0):h(height):pad(0, pad, 0, pad):gap(gap)
	:align("center"):bg(theme:color("surface")))
	:onClick({ type = "open", overlay = "now_playing"})
	:canvas(function(canvas)
		local line = math.max(2, theme:px(2))
		canvas:rect(0, canvas.height - line, canvas.width, line, theme:color("text", 0.1))
		if fraction > 0 then
			canvas:rect(0, canvas.height - line, math.floor(canvas.width * fraction), line,
			theme:color("accent"))
		end
	end)
	:children({
	render.cover(app, album, art, theme:radius("sm")),
	div():style(sty():column():w(math.max(theme:px(70), textWidth)):hrel(1.0)
	:justify("center"):gap(1)):children({
	text(track.title):style(theme:s():w(math.max(theme:px(70), textWidth)):text(theme:type("sm"))
	:weight("semibold"):fg(theme:color("text")):ellipsis()),
	text(track.artist):style(theme:s():w(math.max(theme:px(70), textWidth)):text(theme:type("xs"))
	:fg(theme:color("muted")):ellipsis()),
	}),
	div():style(sty():size(playSize, playSize):radius(theme:radius("full")):bg(theme:color("accent"))
	:align("center"):justify("center")):onClick({ type = "togglePlay"})
	:children(ui.icons.element(playing and "pause" or "play", theme:px(19), theme.accentInk)),
	render.iconButton(app, "next", nextSize, { type = "next"}),
	})
end

return playerBar
