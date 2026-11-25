-- The three dots open the larger per-track menu: the rating, tagging, playlists, and the album and
-- artist pages that the compact controls no longer have room to grow another row for.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local nowPlaying = require("beat.app.overlays.now_playing")
local names = require("beat.music.names")
local popup = require("beat.app.components.popup")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

-- Every row leads with the same glyph column, so the labels line up, and the glyph is the muted
-- colour of a secondary control rather than the label's own.
local ICON_SIZE = 18
local ICON_GAP = 10

---@type table<beat.Theme, wonderland.StyleBuilder>
local iconBoxes = setmetatable({}, { __mode = "k" })

---@param theme beat.Theme
---@return wonderland.StyleBuilder
local function iconBox(theme)
	local box = iconBoxes[theme]
	if box == nil then
		local size = theme:px(ICON_SIZE)
		box = sty():size(size, size):row():align("center"):justify("center")
		iconBoxes[theme] = box
	end
	return box
end

---@param ctx beat.ui.Context
---@param theme beat.Theme
---@param name string?
---@return wonderland.Element
local function iconColumn(ctx, theme, name)
	if name == nil then return div():style(iconBox(theme)) end
	return div():style(iconBox(theme)):children(ui.icon(ctx, {
		name = name,
		size = theme:px(ICON_SIZE),
		colour = theme:color("muted")
	}))
end

-- The rating row's handler, one per track rather than one per frame the menu is open.
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

--- A label row in the two now-playing panels. They are deliberately taller than a context menu
--- row: these are the larger screens' utility menus rather than a right-click's short list.
---@param app beat.App
---@param ctx beat.ui.Context
---@param icon string?
---@param label string
---@param action any
---@param width number
---@param height number
local function nowPlayingEntry(app, ctx, icon, label, action, width, height)
	local theme = app.services.appearance.theme
	return div()
		:style(
			sty()
				:row():w(width):h(height):pad(0, theme:px(12), 0, theme:px(12)):gap(theme:px(ICON_GAP)):align("center")
				:radius(theme:radius("sm"))
		)
		:hover(
			sty()
				:row():w(width):h(height):pad(0, theme:px(12), 0, theme:px(12)):gap(theme:px(ICON_GAP)):align("center")
				:radius(theme:radius("sm")):bg(theme:color("hover"))
		):onClick(action)
		:children({
			iconColumn(ctx, theme, icon),
			text(label):style(theme:s():wrel(1.0):text(theme:type("sm")):weight("medium"):fg(theme:color("text")):ellipsis())
		})
end

---@class beat.MoreAnchor
---@field rowWidth number # The tool row's width; the menu stays inside it
---@field room beat.ToolRoom
---@field x number # Where the three dots start in the row

---@class beat.MoreState
---@field anchor beat.MoreAnchor?

---@class beat.MoreOverlay: beat.OverlaySurface
local more = { light = true, anchored = true }

---@param app beat.App
function more.new(app)
	popup.open(app, "moreMenu")
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
	-- The queue has its own button beside the three dots, so it is not repeated here.
	---@type { [1]: string, [2]: string, [3]: beat.Message }[]
	local entries = {
		{ "Tag track", "tag", { type = "open", overlay = "tag_picker", id = track.id } },
		{ "Add to playlist", "playlists", { type = "open", overlay = "playlist_picker", kind = "track", id = track.id } }
	}
	if album ~= nil then
		entries[#entries + 1] = { "Go to album", "folder", { type = "navigate", page = { kind = "album", id = album.id } } }
		entries[#entries + 1] = { "Go to artist", "library", { type = "navigate", page = { kind = "artist", id = album.artistId } } }
	end

	-- Under its own button, unless that would carry it past the end of the row.
	local width = math.min(theme:px(252), rowWidth)
	x = math.max(0, math.min(x, rowWidth - width))
	local rowHeight = theme:px(40)
	local padding = theme:px(8)
	local gap = theme:px(2)
	-- The rating leads, as a row of its own: it is the one thing here that is set rather than
	-- opened, so it is the stars themselves rather than a label that leads somewhere else. It is
	-- there only while the ratings plugin is loaded; the rows below are the rest of the menu.
	local ratings = app.registry:hasPlugin("ratings")
	local rowCount = #entries + (ratings and 1 or 0)
	local height = padding * 2 + rowCount * rowHeight + math.max(0, rowCount - 1) * gap
	local ctx = app:ui(window)
	local rows = {}
	if ratings then
		rows[1] = div()
			:style(
				sty()
					:row():w(width - padding * 2):h(rowHeight):pad(0, theme:px(12), 0, theme:px(12))
					:gap(theme:px(ICON_GAP)):align("center")
			)
			:children(
				{
					iconColumn(ctx, theme, "star"),
					text("Rating"):style(theme:s():w("auto"):text(theme:type("sm")):weight("medium"):fg(theme:color("muted"))),
					ui.rating(
						ctx,
						{
							value = app.services.collections.taxonomy:rating(names.trackKey(track)),
							onRate = rateFor(track),
							size = theme:px(18)
						}
					)
				}
			)
	end
	for _, entry in ipairs(entries) do
		rows[#rows + 1] = nowPlayingEntry(app, ctx, entry[2], entry[1], entry[3], width - padding * 2, rowHeight)
	end

	local panel = div()
		:style(
			sty()
				:w(width):h(height):column():pad(padding):gap(gap):radius(theme:radius("md")):bg(theme:color("elevated"))
				:border(theme:px(1), theme:color("border")):shadow(0, theme:px(14), theme:px(36), "#00000099")
		):onClick({ type = "keep" }):children(rows)

	return nowPlaying.toolPanel(app, panel, x, width, height, room, "moreMenu")
end

return more
