-- The playlist a New playlist button starts: a name, and the tags that make it follow tracks by
-- themselves rather than only hold what is dropped on it.
local wonderland = require("wonderland")
local render = require("beat.app.ui")
local metrics = require("beat.app.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.PlaylistDialogState
---@field smart boolean
---@field name string
---@field tagIds table<number, boolean>
---@field match "all"|"any"

---@type beat.OverlaySurface
local playlistDialog = {}

---@param params { smart: boolean? }
function playlistDialog.new(app, params)
	app:close("tag_picker")
	app:close("tag_dialog")
	app:close("playlist_picker")
	-- The caret goes in as soon as the dialog opens, so typing the name is the next thing.
	app:focusField("playlistName")
	---@type beat.PlaylistDialogState
	return { smart = params.smart == true, name = "", tagIds = {}, match = "all"}
end

function playlistDialog.close(app, overlay)
	app:focusField(nil)
end

function playlistDialog.update(app, overlay, message)
	local state = overlay.state --[[@as beat.PlaylistDialogState]]
	local kind = message.type
	if kind == "playlistDraft" then
		state.name = message.value or ""
		app:refresh()
		return true
	elseif kind == "playlistDraftTag" then
		if message.id ~= nil then
			if state.tagIds[message.id] then state.tagIds[message.id] = nil
			else state.tagIds[message.id] = true end
			app:refresh()
		end
		return true
	elseif kind == "playlistDraftMatch" then
		state.match = message.value == "any" and "any" or "all"
		app:refresh()
		return true
	elseif kind == "createPlaylist" then
		local tagIds = {}
		for id in pairs(state.tagIds) do tagIds[#tagIds + 1] = id end
		table.sort(tagIds)
		local playlist = app.taxonomy:addPlaylist(state.name, #tagIds > 0, tagIds,
		state.match, { manual = true})
		if playlist == nil then
			app:toast("Choose a playlist name", "error")
		else
			app:saveTaxonomy()
			app:close(overlay)
			app:toast("Playlist created · " .. playlist.name)
		end
		app:refresh()
		return true
	end
	return false
end

function playlistDialog.view(app, overlay, window)
	local state = overlay.state --[[@as beat.PlaylistDialogState]]
	local theme = app.theme
	local tags = app.taxonomy:visibleTags()
	local panelWidth = metrics.panelWidth(app, window, 440)
	local pad = theme:px(18)
	local content = panelWidth - pad * 2
	local children = {
	text("New playlist"):style(
	theme:s():text(theme:type("lg")):weight("bold"):fg(theme:color("text"))),
	text("Tags add tracks automatically; you can still add the rest by hand."):style(
	theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()),
	render.field(app, "playlistName", state.name, "Playlist name",
	function(value) return { type = "playlistDraft", value = value} end,
	function() return { type = "createPlaylist"} end),
	}

	local pills = render.tagPills(app, tags, state.tagIds, function(tag)
		return { type = "playlistDraftTag", id = tag.id}
	end, content, metrics.mobile(app, window.width) and 2 or 3)
	children[#children + 1] = pills or text("Create a tag to make this playlist smart too."):style(
	theme:s():text(theme:type("sm")):fg(theme:color("faint")))
	children[#children + 1] = div():style(sty():row():h(theme:px(28)):gap(theme:px(8))
	:align("center")):children({
	text("Match"):style(theme:s():text(theme:type("xs")):fg(theme:color("muted"))),
	render.button(app, "All tags", { type = "playlistDraftMatch", value = "all"},
	{ height = theme:px(26), width = theme:px(82), primary = state.match == "all"}),
	render.button(app, "Any tag", { type = "playlistDraftMatch", value = "any"},
	{ height = theme:px(26), width = theme:px(82), primary = state.match == "any"}),
	})

	children[#children + 1] = div():style(sty():row():h(theme:px(32)):gap(theme:px(8))
	:align("center"):justify("end")):children({
	render.button(app, "Cancel", { type = "dismiss"}, { height = theme:px(30),
	width = theme:px(80)}),
	render.button(app, "Create", { type = "createPlaylist"}, { primary = true, height = theme:px(30),
	width = theme:px(86)}),
	})

	local tagRows = math.max(1, math.ceil(math.min(#tags, 12) / 3))
	local pillsHeight = #tags > 0 and (tagRows * theme:px(28) + math.max(0, tagRows - 1) * theme:px(8)
	+(#tags > 12 and theme:px(18) or 0)) or theme:px(20)
	local rowCount = state.smart and 6 or 4
	local panelHeight = pad * 2 + theme:px(24) + theme:px(20) + theme:px(34) + theme:px(32)
	+theme:px(10) * (rowCount - 1) + (state.smart and pillsHeight + theme:px(28) or 0)
	local panel = div()
	:style(sty():w(panelWidth):h(panelHeight):column():pad(pad):gap(theme:px(10)):radius(theme:radius("lg"))
	:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(16), theme:px(42), "#00000080"))
	:onClick({ type = "keep"})
	:children(children)

	return div():style(sty():fill():offset(0, 0):z(120):column():align("center"):justify("center")
	:bg(theme:color("overlay"))):onClick({ type = "dismiss"}):children({ panel})
end

return playlistDialog
