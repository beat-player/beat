-- The menu an album answers a right click with, where the pointer is.
local wonderland = require("wonderland")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.AlbumMenuState
---@field id number
---@field x number
---@field y number

---@type beat.OverlaySurface
local albumMenu = { light = true}

---@param params { id: number, x: number?, y: number? }
function albumMenu.new(app, params)
	local album = app.services.library.current ~= nil and app.services.library.current:album(params.id) or nil
	if album == nil then return nil end
	---@type beat.AlbumMenuState
	return { id = album.id, x = params.x or 0, y = params.y or 0}
end

function albumMenu.update(app, overlay, message)
	local state = overlay.state --[[@as beat.AlbumMenuState]]
	local kind = message.type
	if kind == "albumMenuPlay" or kind == "albumMenuNext" or kind == "albumMenuQueue" then
		local album = app.services.library.current and app.services.library.current:album(state.id)
		app:close(overlay)
		if album ~= nil then
			if kind == "albumMenuPlay" then
				app.services.playback.player:playAlbum(album)
			elseif kind == "albumMenuNext" then
				app.services.playback.player:playNext(album.tracks)
				app.services.toasts:show("Playing next · " .. album.title)
			else
				app.services.playback.player:addToQueue(album.tracks)
				app.services.toasts:show("Added to queue · " .. album.title)
			end
		end
		app:refresh()
		return true
	end
	return false
end

function albumMenu.view(app, overlay, window)
	local state = overlay.state --[[@as beat.AlbumMenuState]]
	local library = app.services.library.current
	if library == nil then return nil end
	local album = library:album(state.id)
	if album == nil then return nil end

	local theme = app.services.appearance.theme
	local width = theme:px(218)
	local rowHeight = theme:px(34)
	local height = theme:px(8 * 2 + 34 * 4 + 2 * 3)
	local margin = theme:px(8)
	local x = math.max(margin, math.min(state.x, window.width - width - margin))
	local y = math.max(margin, math.min(state.y, window.height - height - margin))

	local rows = {}
	---@param label string
	---@param action any
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

	entry("Play album", { type = "albumMenuPlay", id = album.id})
	entry("Add to playlist", { type = "open", overlay = "playlist_picker", kind = "album",
	id = album.id})
	entry("Play next", { type = "albumMenuNext", id = album.id})
	entry("Add to queue", { type = "albumMenuQueue", id = album.id})

	local panel = div()
	:style(sty():w(width):h(height):column():pad(theme:px(8)):gap(theme:px(2))
	:radius(theme:radius("md")):bg(theme:color("elevated"))
	:border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(12), theme:px(30), "#00000080"))
	:onClick({ type = "keep"})
	:children(rows)

	return div()
	:style(sty():fill():offset(0, 0):z(120))
	:onClick({ type = "dismiss"})
	:children({
	div():style(sty():w(width):h(height):offset(x, y)):children({ panel}),
	})
end

return albumMenu
