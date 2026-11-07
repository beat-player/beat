-- The menu a track row answers a right click with, where the pointer is.
local wonderland = require("wonderland")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.TrackMenuState
---@field id number
---@field x number
---@field y number

---@type beat.OverlaySurface
local trackMenu = { light = true}

---@param params { id: number, x: number?, y: number? }
function trackMenu.new(app, params)
	local track = app.services.library.current ~= nil and app.services.library.current:track(params.id) or nil
	if track == nil then return nil end
	---@type beat.TrackMenuState
	return { id = track.id, x = params.x or 0, y = params.y or 0}
end

function trackMenu.update(app, overlay, message)
	local state = overlay.state --[[@as beat.TrackMenuState]]
	local kind = message.type
	if kind == "trackMenuPlay" then
		app:close(overlay)
		local track = app.services.library.current and app.services.library.current:track(state.id)
		if track ~= nil then app.services.playback.player:playTrack(track) end
		return true
	elseif kind == "trackMenuPlaylist" then
		app:close(overlay)
		app:open("playlist_picker", { kind = "track", id = state.id})
		return true
	end
	return false
end

function trackMenu.view(app, overlay, window)
	local state = overlay.state --[[@as beat.TrackMenuState]]
	local theme = app.services.appearance.theme
	local width = theme:px(210)
	local rowHeight = theme:px(34)
	local height = theme:px(8 * 2 + 34 * 2 + 2)
	local margin = theme:px(8)
	local x = math.max(margin, math.min(state.x, window.width - width - margin))
	local y = math.max(margin, math.min(state.y, window.height - height - margin))
	local rows = {}
	local function entry(label, action)
		rows[#rows + 1] = div()
		:style(sty():row():wrel(1.0):h(rowHeight):pad(0, theme:px(12), 0, theme:px(12))
		:align("center"):radius(theme:radius("sm")))
		:hover(sty():row():wrel(1.0):h(rowHeight):pad(0, theme:px(12), 0, theme:px(12))
		:align("center"):radius(theme:radius("sm")):bg(theme:color("hover")))
		:onClick(action)
		:children(text(label):style(theme:s():text(theme:type("sm")):fg(theme:color("text"))
		:ellipsis()))
	end
	entry("Play now", { type = "trackMenuPlay"})
	entry("Add to playlist", { type = "trackMenuPlaylist"})

	local panel = div()
	:style(sty():w(width):h(height):column():pad(theme:px(8)):gap(theme:px(2))
	:radius(theme:radius("md")):bg(theme:color("elevated"))
	:border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(12), theme:px(30), "#00000080"))
	:onClick({ type = "keep"})
	:children(rows)

	return div():style(sty():fill():offset(0, 0):z(120))
	:onClick({ type = "dismiss"})
	:children({ div():style(sty():w(width):h(height):offset(x, y)):children({ panel})})
end

return trackMenu
