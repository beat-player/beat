-- One context menu for every list in the app. The open message names the menu and the thing it is
-- for; the entries are whatever the registry has for that menu, in order. A plugin adds an entry
-- by registering an action rather than by writing a second menu, so the look and the closing rules
-- stay in one place. A menu whose subject has a rating leads with its stars: they set a value
-- rather than open something, so they are a row of their own instead of an action.
local wonderland = require("wonderland")
local ui = require("beat-ui")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.MenuState
---@field menu string
---@field id number
---@field x number
---@field y number

-- Each menu keeps the width it had when it was its own overlay: enough for its longest entry.
local WIDTH = { album = 218, track = 210, playlist = 196 }

--- What the entries are shown for. The menu is refused when the library or the taxonomy no longer
--- has the thing it was opened on, which is what the three menus used to decide one at a time.
---@type table<string, fun(app: beat.App, id: number): table?>
local CONTEXT = {
	---@param app beat.App
	---@param id number
	album = function(app, id)
		local library = app.services.library.current
		local album = library ~= nil ? (library:album(id)) : nil
		return album ~= nil ? { album = album } : nil
	end,
	---@param app beat.App
	---@param id number
	track = function(app, id)
		local library = app.services.library.current
		local track = library ~= nil ? (library:track(id)) : nil
		return track ~= nil ? { track = track } : nil
	end,
	---@param app beat.App
	---@param id number
	playlist = function(app, id)
		local playlist = app.services.collections.taxonomy:playlist(id)
		return playlist ~= nil ? { playlist = playlist } : nil
	end
}

--- The menus whose subject can be rated, with its rating and the message a star sends. A star
--- sends its message like any entry, and the menu closes behind it the same way.
---@type table<string, fun(app: beat.App, ctx: table): { value: number, onRate: fun(stars: number): table }>
local RATING = {
	---@param app beat.App
	---@param ctx { album: beat.Album }
	album = function(app, ctx)
		local album = ctx.album
		return {
			value = app.services.collections.taxonomy:albumRating(album.key),
			onRate = |stars| -> { type = "rateAlbum", id = album.id, stars = stars }
		}
	end
}

---@class beat.MenuOverlay: beat.OverlaySurface
local menu = { light = true }

---@param params { menu: string, id: number, x: number?, y: number? }
---@param app beat.App
function menu.new(app, params)
	local context = params.menu ~= nil and CONTEXT[params.menu] or nil
	if context == nil or params.id == nil then return nil end
	if context(app, params.id) == nil then return nil end
	---@type beat.MenuState
	return { menu = params.menu, id = params.id, x = params.x or 0, y = params.y or 0 }
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.MenuState>
---@param window wonderland.RenderWindow
function menu.view(app, overlay, window)
	local state = overlay.state
	local context = CONTEXT[state.menu]
	local ctx = context ~= nil ? context(app, state.id) : nil
	if ctx == nil then return nil end

	local entries = app.registry:actions(state.menu, ctx)
	local rateWith = RATING[state.menu]
	local rating = rateWith ~= nil and rateWith(app, ctx) or nil
	local theme = app.services.appearance.theme
	local uiCtx = app:ui(window)
	local width = theme:px(WIDTH[state.menu] or 218)
	local rowHeight = theme:px(34)
	local count = #entries + (rating ~= nil and 1 or 0)
	local height = theme:px(8 * 2 + 34 * count + 2 * math.max(0, count - 1))
	local margin = theme:px(8)
	local x = math.max(margin, math.min(state.x, window.width - width - margin))
	local y = math.max(margin, math.min(state.y, window.height - height - margin))

	local rows = {}
	if rating ~= nil then
		rows[1] = div()
			:style(sty():row():w(width - theme:px(16)):h(rowHeight):pad(0, theme:px(12), 0, theme:px(12)):align("center"))
			:children(
				{
					text("Rating"):style(theme:s():w("auto"):text(theme:type("sm")):fg(theme:color("muted"))),
					ui.rating(uiCtx, { value = rating.value, onRate = rating.onRate, size = theme:px(16) })
				}
			)
	end
	for _, entry in ipairs(entries) do
		local label = theme:s():text(theme:type("sm")):fg(theme:color(entry.tone or "text")):ellipsis()
		if entry.tone == "danger" then label = label:weight("semibold") end
		rows[#rows + 1] = ui.listRow(
			uiCtx,
			{
				height = rowHeight,
				padding = theme:px(12),
				onClick = entry.message,
				children = { text(entry.title):style(label) }
			}
		)
	end

	local panel = div()
		:style(
			sty()
				:w(width):h(height):column():pad(theme:px(8)):gap(theme:px(2)):radius(theme:radius("md"))
				:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
				:shadow(0, theme:px(12), theme:px(30), "#00000080")
		):onClick({ type = "keep" }):children(rows)

	return div()
		:style(sty():fill():offset(0, 0):z(120)):onClick({ type = "dismiss" })
		:children({ div():style(sty():w(width):h(height):offset(x, y)):children({ panel }) })
end

return menu
