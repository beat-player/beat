-- The panel that adds albums to a playlist, opened from the playlist's own +.
local wonderland = require("wonderland")
local render = require("beat.app.ui")
local metrics = require("beat.app.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.PlaylistAdderState
---@field playlistId number
---@field query string

---@type beat.OverlaySurface
local playlistAdder = {}

---@param params { playlistId: number }
function playlistAdder.new(app, params)
	local playlist = app.taxonomy:playlist(params.playlistId)
	if playlist == nil or app.library == nil then return nil end
	-- The search field is where typing goes the moment the panel opens.
	app:focusField("playlistAddSearch")
	---@type beat.PlaylistAdderState
	return { playlistId = playlist.id, query = ""}
end

function playlistAdder.close(app)
	app:focusField(nil)
end

function playlistAdder.update(app, overlay, message)
	local state = overlay.state --[[@as beat.PlaylistAdderState]]
	local kind = message.type
	if kind == "playlistAdderQuery" then
		state.query = message.value or ""
		app:refresh()
		return true
	elseif kind == "playlistAddAlbum" then
		local playlist = app.taxonomy:playlist(state.playlistId)
		local album = app.library ~= nil and app.library:album(message.id --[[@as number]]) or nil
		if playlist ~= nil and album ~= nil then
			app.taxonomy:setPlaylistAlbum(playlist, album)
			app:saveTaxonomy()
			app:toast("Added " .. album.title .. " to " .. playlist.name)
		end
		app:refresh()
		return true
	end
	return false
end

function playlistAdder.view(app, overlay, window)
	local state = overlay.state --[[@as beat.PlaylistAdderState]]
	local playlist = app.taxonomy:playlist(state.playlistId)
	if playlist == nil or app.library == nil then return nil end
	local theme = app.theme
	local panelWidth = metrics.panelWidth(app, window, 520)
	local rowWidth = panelWidth - theme:px(32)
	local albums
	if state.query == "" then
		albums = {}
		for at = 1, math.min(8, #app.library.albums) do albums[#albums + 1] = app.library.albums[at] end
	else
		albums = app.library:search(state.query)
	end
	local rows = {}
	for at = 1, math.min(8, #albums) do
			local album = albums[at]
			---@cast album beat.Album
			rows[#rows + 1] = div():style(sty():row():wrel(1.0):h(theme:px(42)):gap(theme:px(10))
			:pad(0, theme:px(6), 0, theme:px(6)):align("center"):radius(theme:radius("sm")))
			:hover(sty():row():wrel(1.0):h(theme:px(42)):gap(theme:px(10)):pad(0, theme:px(6),
			0, theme:px(6)):align("center"):radius(theme:radius("sm")):bg(theme:color("hover")))
			:onClick({ type = "playlistAddAlbum", id = album.id})
			:children({
			render.cover(app, album, theme:px(32), theme:radius("sm")),
			div():style(sty():column():w(rowWidth - theme:px(78)):gap(0)):children({
			text(album.title):style(theme:s():wrel(1.0):text(theme:type("sm")):weight("semibold")
			:fg(theme:color("text")):ellipsis()),
			text(album.artist):style(theme:s():wrel(1.0):text(theme:type("xs")):fg(theme:color("muted"))
			:ellipsis()),
			}),
			render.iconButton(app, "add", theme:px(26), { type = "playlistAddAlbum", id = album.id}),
			})
		end

	local panelHeight = theme:px(520)
	local panel = div()
	:style(sty():w(panelWidth):h(panelHeight):column():pad(theme:px(16)):gap(theme:px(10))
	:radius(theme:radius("lg")):bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(16), theme:px(42), "#00000080"))
	:onClick({ type = "keep" })
	:children({
	div():style(sty():row():wrel(1.0):h(theme:px(28)):gap(theme:px(8)):align("center")):children({
	text("Add to " .. playlist.name):style(theme:s():w(rowWidth - theme:px(28)):text(theme:type("lg"))
	:weight("bold"):fg(theme:color("text")):ellipsis()),
	render.iconButton(app, "close", theme:px(28), { type = "dismiss" }),
	}),
	render.field(app, "playlistAddSearch", state.query, "Search albums",
	function(value) return { type = "playlistAdderQuery", value = value} end,
	function() return nil end),
	div():style(sty():column():wrel(1.0):h(theme:px(8 * 44)):gap(theme:px(2))):children(rows),
	text(#albums > 8 and "Showing the first 8; search to narrow the list."
	or "Click an album to add every track in it."):style(theme:s():text(theme:type("xs"))
	:fg(theme:color("faint"))),
	})

	return div():style(sty():fill():offset(0, 0):z(122):column():align("center"):justify("center")
	:bg(theme:color("overlay"))):onClick({ type = "dismiss" }):children({ panel})
end

return playlistAdder
