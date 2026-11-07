-- The playlist row's secondary click. Deleting removes the playlist and the hidden tag that
-- holds its hand-added tracks; the tag definitions themselves are untouched.
local wonderland = require("wonderland")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.PlaylistMenuState
---@field id number
---@field x number
---@field y number

---@type beat.OverlaySurface
local playlistMenu = { light = true}

---@param params { id: number, x: number?, y: number? }
function playlistMenu.new(app, params)
	local playlist = app.taxonomy:playlist(params.id)
	if playlist == nil then return nil end
	---@type beat.PlaylistMenuState
	return { id = playlist.id, x = params.x or 0, y = params.y or 0}
end

function playlistMenu.update(app, overlay, message)
	local state = overlay.state --[[@as beat.PlaylistMenuState]]
	if message.type == "deletePlaylist" then
		app:close(overlay)
		app:deletePlaylist(state.id)
		app:refresh()
		return true
	end
	return false
end

function playlistMenu.view(app, overlay, window)
	local state = overlay.state --[[@as beat.PlaylistMenuState]]
	local playlist = app.taxonomy:playlist(state.id)
	if playlist == nil then return nil end

	local theme = app.theme
	local width = theme:px(196)
	local rowHeight = theme:px(34)
	local height = theme:px(8 * 2 + 34)
	local margin = theme:px(8)
	local x = math.max(margin, math.min(state.x, window.width - width - margin))
	local y = math.max(margin, math.min(state.y, window.height - height - margin))

	local row = div()
	:style(sty():row():wrel(1.0):h(rowHeight):pad(0, theme:px(12), 0, theme:px(12))
	:align("center"):radius(theme:radius("sm")))
	:hover(sty():row():wrel(1.0):h(rowHeight):pad(0, theme:px(12), 0, theme:px(12))
	:align("center"):radius(theme:radius("sm")):bg(theme:color("hover")))
	:onClick({ type = "deletePlaylist", id = playlist.id})
	:children(text("Delete playlist"):style(theme:s():text(theme:type("sm")):weight("semibold")
	:fg(theme:color("danger")):ellipsis()))

	local panel = div()
	:style(sty():w(width):h(height):column():pad(theme:px(8)):gap(theme:px(2))
	:radius(theme:radius("md")):bg(theme:color("elevated"))
	:border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(12), theme:px(30), "#00000080"))
	:onClick({ type = "keep"})
	:children({ row})

	return div()
	:style(sty():fill():offset(0, 0):z(120))
	:onClick({ type = "dismiss"})
	:children({
	div():style(sty():w(width):h(height):offset(x, y)):children({ panel}),
	})
end

return playlistMenu
