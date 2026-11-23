-- A new tag's name, typed once and created on Enter or on the button.
local wonderland = require("wonderland")
local ui = require("beat-ui")

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
	return { draft = "" }
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
	if message.type == "tagDraft" then
		state.draft = message.value or ""
		app:refresh()
		return true
	elseif message.type == "createTag" then
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
	local ctx = app:ui(window)
	local panelWidth = ctx:panelWidth(380)
	local pad = theme:px(20)
	local gap = theme:px(14)
	local named = state.draft:match("%S") ~= nil
	local panelHeight = pad * 2 + theme:px(26) + theme:px(34) + theme:px(18) + theme:px(38) + gap * 3
	local panel = div()
		:style(
			sty()
				:w(panelWidth):h(panelHeight):column():pad(pad):gap(gap):radius(theme:radius("lg"))
				:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
				:shadow(0, theme:px(16), theme:px(42), "#00000080")
		):onClick({ type = "keep" })
		:children(
			{
				text("New tag"):style(theme:s():h(theme:px(26)):text(theme:type("lg")):weight("bold"):fg(theme:color("text"))),
				ui.field(
					ctx,
					{
						name = "newTag",
						value = state.draft,
						placeholder = "Tag name",
						oninput = |value| -> { type = "tagDraft", value = value },
						onsubmit = || -> { type = "createTag" }
					}
				),
				text("Each tag is also a smart playlist.")
					:style(theme:s():wrel(1.0):h(theme:px(18)):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()),
				div()
					:style(sty():row():wrel(1.0):h(theme:px(38)):gap(theme:px(8)):align("center"):justify("end"))
					:children(
						{
							ui.button(
								ctx,
								{ label = "Cancel", onClick = { type = "dismiss" }, variant = "quiet", height = theme:px(36), width = theme:px(84) }
							),
							-- Create is quiet until there is a name to create the tag with.
							ui.button(
								ctx,
								{
									label = "Create",
									onClick = named and { type = "createTag" } or { type = "keep" },
									variant = named and "primary" or "secondary",
									height = theme:px(36),
									width = theme:px(96)
								}
							)
						}
					)
			}
		)

	return div()
		:style(sty():fill():offset(0, 0):z(120):column():align("center"):justify("center"):bg(theme:color("overlay")))
		:onClick({ type = "dismiss" }):children({ panel })
end

return tagDialog
