-- The three dots open the larger per-track menu: tagging, playlists, and the album and artist
-- pages that the compact controls no longer have room to grow another row for.
local wonderland = require("wonderland")
local nowPlaying = require("beat.app.overlays.now_playing")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

--- A label row in the two now-playing panels. They are deliberately taller than a context menu
--- row: these are the larger screens' utility menus rather than a right-click's short list.
---@param app beat.App
---@param label string
---@param action any
---@param width number
---@param height number
---@return wonderland.Element
local function nowPlayingEntry(app, label, action, width, height)
	local theme = app.services.appearance.theme
	return div()
	:style(sty():row():w(width):h(height):pad(0, theme:px(12), 0, theme:px(12))
	:align("center"):radius(theme:radius("sm")))
	:hover(sty():row():w(width):h(height):pad(0, theme:px(12), 0, theme:px(12))
	:align("center"):radius(theme:radius("sm")):bg(theme:color("hover")))
	:onClick(action)
	:children(text(label):style(theme:s():wrel(1.0):text(theme:type("sm"))
	:weight("medium"):fg(theme:color("text")):ellipsis()))
end

---@class beat.MoreAnchor
---@field rowWidth number # The tool row's width; the menu stays inside it
---@field room beat.ToolRoom
---@field x number # Where the three dots start in the row

---@class beat.MoreState
---@field anchor beat.MoreAnchor?

---@type beat.OverlaySurface
local more = { light = true, anchored = true}

function more.new()
	---@type beat.MoreState
	return {}
end

function more.update(app, overlay, message)
	if message.type == "toggleMore" then
		-- The three dots close what they opened rather than opening a second menu.
		app:close(overlay)
		return true
	end
	return false
end

---@param app beat.App
---@param overlay beat.OverlayInstance
---@param _window wonderland.RenderWindow
---@return wonderland.Element?
function more.view(app, overlay, _window)
	local state = overlay.state --[[@as beat.MoreState]]
	local anchor = state.anchor
	if anchor == nil then return nil end
	local track = app.services.playback:current()
	if track == nil then return nil end
	local rowWidth = anchor.rowWidth
	local room = anchor.room
	local x = anchor.x
	local theme = app.services.appearance.theme
	local album = app.services.library.current and app.services.library.current:album(track.albumId) or nil
	local entries = {
	{ "Tag track", { type = "open", overlay = "tag_picker", id = track.id}},
	{ "Add to playlist", { type = "open", overlay = "playlist_picker", kind = "track",
	id = track.id}},
	}
	if album ~= nil then
		entries[#entries + 1] = { "Go to album",
		{ type = "navigate", page = { kind = "album", id = album.id}}}
		entries[#entries + 1] = { "Go to artist",
		{ type = "navigate", page = { kind = "artist", id = album.artistId}}}
	end
	entries[#entries + 1] = { "Open queue", { type = "open", overlay = "queue"}}

	-- Under its own button, unless that would carry it past the end of the row.
	local width = math.min(theme:px(252), rowWidth)
	x = math.max(0, math.min(x, rowWidth - width))
	local rowHeight = theme:px(40)
	local padding = theme:px(8)
	local gap = theme:px(2)
	local height = padding * 2 + #entries * rowHeight + math.max(0, #entries - 1) * gap
	local rows = {}
	for _, entry in ipairs(entries) do
			rows[#rows + 1] = nowPlayingEntry(app, entry[1] --[[@as string]], entry[2],
			width - padding * 2, rowHeight)
		end

	local panel = div()
	:style(sty():w(width):h(height):column():pad(padding):gap(gap)
	:radius(theme:radius("md")):bg(theme:color("elevated"))
	:border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(14), theme:px(36), "#00000099"))
	:onClick({ type = "keep"})
	:children(rows)

	return nowPlaying.toolPanel(app, panel, x, width, height, room)
end

return more
