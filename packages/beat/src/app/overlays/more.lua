-- The three dots open the larger per-track menu: the rating, tagging, playlists, and the album and
-- artist pages that the compact controls no longer have room to grow another row for.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local nowPlaying = require("beat.app.overlays.now_playing")
local names = require("beat.music.names")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

--- A label row in the two now-playing panels. They are deliberately taller than a context menu
--- row: these are the larger screens' utility menus rather than a right-click's short list.
---@param app beat.App
---@param label string
---@param action any
---@param width number
---@param height number
local function nowPlayingEntry(app, label, action, width, height)
	local theme = app.services.appearance.theme
	return div()
		:style(
			sty():row():w(width):h(height):pad(0, theme:px(12), 0, theme:px(12)):align("center"):radius(theme:radius("sm"))
		)
		:hover(
			sty()
				:row():w(width):h(height):pad(0, theme:px(12), 0, theme:px(12)):align("center"):radius(theme:radius("sm"))
				:bg(theme:color("hover"))
		):onClick(action)
		:children(
			text(label):style(theme:s():wrel(1.0):text(theme:type("sm")):weight("medium"):fg(theme:color("text")):ellipsis())
		)
end

---@class beat.MoreAnchor
---@field rowWidth number # The tool row's width; the menu stays inside it
---@field room beat.ToolRoom
---@field x number # Where the three dots start in the row

---@class beat.MoreState
---@field anchor beat.MoreAnchor?

---@class beat.MoreOverlay: beat.OverlaySurface
local more = { light = true, anchored = true }

function more.new()
	---@type beat.MoreState
	return {}
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.MoreState>
---@param message beat.Message
function more.update(app, overlay, message)
	if message.type == "toggleMore" then
		-- The three dots close what they opened rather than opening a second menu.
		app:close(overlay)
		return true
	end
	return false
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.MoreState>
---@param window wonderland.RenderWindow
---@return wonderland.Element?
function more.view(app, overlay, window)
	local state = overlay.state
	local anchor = state.anchor
	if anchor == nil then return nil end
	local track = app.services.playback:current()
	if track == nil then return nil end
	local rowWidth = anchor.rowWidth
	local room = anchor.room
	local x = anchor.x
	local theme = app.services.appearance.theme
	local album = app.services.library.current ? (app.services.library.current:album(track.albumId)) : nil
	---@type { [1]: string, [2]: beat.Message }[]
	local entries = {
		{ "Tag track", { type = "open", overlay = "tag_picker", id = track.id } },
		{ "Add to playlist", { type = "open", overlay = "playlist_picker", kind = "track", id = track.id } }
	}
	if album ~= nil then
		entries[#entries + 1] = { "Go to album", { type = "navigate", page = { kind = "album", id = album.id } } }
		entries[#entries + 1] = { "Go to artist", { type = "navigate", page = { kind = "artist", id = album.artistId } } }
	end
	entries[#entries + 1] = { "Open queue", { type = "open", overlay = "queue" } }

	-- Under its own button, unless that would carry it past the end of the row.
	local width = math.min(theme:px(252), rowWidth)
	x = math.max(0, math.min(x, rowWidth - width))
	local rowHeight = theme:px(40)
	local padding = theme:px(8)
	local gap = theme:px(2)
	-- The rating leads, as a row of its own: it is the one thing here that is set rather than
	-- opened, so it is the stars themselves rather than a label that leads somewhere else.
	local height = padding * 2 + (#entries + 1) * rowHeight + #entries * gap
	local ctx = app:ui(window)
	local rows = {
		div()
			:style(sty():row():w(width - padding * 2):h(rowHeight):pad(0, theme:px(12), 0, theme:px(12)):align("center"))
			:children(
				{
					text("Rating"):style(theme:s():w("auto"):text(theme:type("sm")):weight("medium"):fg(theme:color("muted"))),
					ui.rating(
						ctx,
						{
							value = app.services.collections.taxonomy:rating(names.trackKey(track)),
							onRate = |stars| -> { type = "rateTrack", id = track.id, stars = stars },
							size = theme:px(18)
						}
					)
				}
			)
	}
	for _, entry in ipairs(entries) do
		rows[#rows + 1] = nowPlayingEntry(app, entry[1], entry[2], width - padding * 2, rowHeight)
	end

	local panel = div()
		:style(
			sty()
				:w(width):h(height):column():pad(padding):gap(gap):radius(theme:radius("md")):bg(theme:color("elevated"))
				:border(theme:px(1), theme:color("border")):shadow(0, theme:px(14), theme:px(36), "#00000099")
		):onClick({ type = "keep" }):children(rows)

	return nowPlaying.toolPanel(app, panel, x, width, height, room)
end

return more
