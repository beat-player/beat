-- A new tag's name, typed once and created on Enter or on the button.
local wonderland = require("wonderland")
local button = require("beat.app.components.button")
local field = require("beat.app.components.field")
local metrics = require("beat.app.components.helpers.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.TagDialogState
---@field draft string

---@class beat.TagDialogOverlay: beat.OverlaySurface
local tagDialog = {}

---@param params table
---@param app beat.App
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

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.TagDialogState>
function tagDialog.close(app, overlay)
	app:focusField(nil)
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.TagDialogState>
---@param message beat.Message
function tagDialog.update(app, overlay, message)
	local state = overlay.state
	local kind = message.type
	if kind == "tagDraft" then
		state.draft = message.value or ""
		app:refresh()
		return true
	elseif kind == "createTag" then
		local tag = app.services.collections.taxonomy:addTag(state.draft)
		if tag == nil then
			app.services.toasts:show("Choose a tag name that is not already used", "error")
		else
			app.services.collections:save()
			app:close(overlay)
			app.services.toasts:show("Tag created · " .. tag.name)
		end
		app:refresh()
		return true
	end
	return false
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.TagDialogState>
---@param window wonderland.RenderWindow
function tagDialog.view(app, overlay, window)
	local state = overlay.state
	local theme = app.services.appearance.theme
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
		field.view(app, {
			name = "newTag",
			value = state.draft,
			placeholder = "Tag name",
			oninput = function(value) return { type = "tagDraft", value = value} end,
			onsubmit = function() return { type = "createTag"} end,
		}),
		div():style(sty():row():h(theme:px(32)):gap(theme:px(8)):align("center"):justify("end")):children({
			button.view(app, {
				label = "Cancel",
				onClick = { type = "dismiss"},
				height = theme:px(30),
				width = theme:px(80),
			}),
			button.view(app, {
				label = "Create",
				onClick = { type = "createTag"},
				primary = true,
				height = theme:px(30),
				width = theme:px(86),
			}),
		}),
	})

	return div():style(sty():fill():offset(0, 0):z(120):column():align("center"):justify("center")
	:bg(theme:color("overlay"))):onClick({ type = "dismiss"}):children({ panel})
end

return tagDialog
