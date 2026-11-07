-- A new tag's name, typed once and created on Enter or on the button.
local wonderland = require("wonderland")
local render = require("beat.app.ui")
local metrics = require("beat.app.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.TagDialogState
---@field draft string

---@type beat.OverlaySurface
local tagDialog = {}

---@param params table
function tagDialog.new(app, params)
	-- One dialog is the one in front: creating a tag from the picker replaces it, as it did when
	-- the picker was a flag the old chain turned off.
	app:close("tag_picker")
	app:close("playlist_dialog")
	app:close("playlist_picker")
	-- The caret goes in as soon as the dialog opens, so typing is the next thing that happens.
	app:focusField("newTag")
	---@type beat.TagDialogState
	return { draft = ""}
end

function tagDialog.close(app, overlay)
	app:focusField(nil)
end

function tagDialog.update(app, overlay, message)
	local state = overlay.state --[[@as beat.TagDialogState]]
	local kind = message.type
	if kind == "tagDraft" then
		state.draft = message.value or ""
		app:refresh()
		return true
	elseif kind == "createTag" then
		local tag = app.taxonomy:addTag(state.draft)
		if tag == nil then
			app:toast("Choose a tag name that is not already used", "error")
		else
			app:saveTaxonomy()
			app:close(overlay)
			app:toast("Tag created · " .. tag.name)
		end
		app:refresh()
		return true
	end
	return false
end

function tagDialog.view(app, overlay, window)
	local state = overlay.state --[[@as beat.TagDialogState]]
	local theme = app.theme
	local panelWidth = metrics.panelWidth(app, window, 360)
	local pad = theme:px(18)
	local panelHeight = pad * 2 + theme:px(24) + theme:px(20) + theme:px(34) + theme:px(32)
	+theme:px(12) * 3
	local panel = div()
	:style(sty():w(panelWidth):h(panelHeight):column():pad(pad):gap(theme:px(12)):radius(theme:radius("lg"))
	:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(16), theme:px(42), "#00000080"))
	:onClick({ type = "keep"})
	:children({
	text("New tag"):style(theme:s():text(theme:type("lg")):weight("bold"):fg(theme:color("text"))),
	text("Tag tracks so playlists and search can find them."):style(
	theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()),
	render.field(app, "newTag", state.draft, "Tag name",
	function(value) return { type = "tagDraft", value = value} end,
	function() return { type = "createTag"} end),
	div():style(sty():row():h(theme:px(32)):gap(theme:px(8)):align("center"):justify("end")):children({
	render.button(app, "Cancel", { type = "dismiss"}, { height = theme:px(30), width = theme:px(80)}),
	render.button(app, "Create", { type = "createTag"}, { primary = true, height = theme:px(30),
	width = theme:px(86)}),
	}),
	})

	return div():style(sty():fill():offset(0, 0):z(120):column():align("center"):justify("center")
	:bg(theme:color("overlay"))):onClick({ type = "dismiss"}):children({ panel})
end

return tagDialog
