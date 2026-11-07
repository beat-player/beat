-- Renaming a saved equalizer preset. The preset is named in its field and deleted from the same
-- dialog, so a name that is no longer wanted is not a trip through the settings. This is only the
-- draft and the focus: whether a name is free, what renaming or deleting does to the presets and
-- what the player hears afterwards are the equalizer service's rules, reached by the one message
-- each button sends.
local wonderland = require("wonderland")
local button = require("beat.app.components.button")
local field = require("beat.app.components.field")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.EqualizerRenameState
---@field name string # The preset as it is named now
---@field draft string

---@type beat.OverlaySurface
local equalizerRename = {}

---@param params { name: string? }
function equalizerRename.new(app, params)
	local preset = app.services.equalizer:find(params.name)
	if preset == nil or not preset.custom then return nil end
	---@type beat.EqualizerRenameState
	local state = { name = preset.name, draft = preset.name}
	app:focusField("equalizerPresetName", #preset.name)
	return state
end

---@param app beat.App
---@param _overlay beat.OverlayInstance
function equalizerRename.close(app, _overlay)
	app:focusField(nil)
end

--- The field's own messages and the cancel button stay here. Save and delete are sent on to the
--- equalizer service, which decides whether they are possible and closes the dialog when they are.
function equalizerRename.update(app, overlay, message)
	local state = overlay.state --[[@as beat.EqualizerRenameState]]
	local kind = message.type
	if kind == "equalizerEditDraft" then
		state.draft = message.value or ""
		app:refresh()
	elseif kind == "cancelEqualizerPresetRename" then
		app:close(overlay)
	else
		return false
	end
	return true
end

---@param app beat.App
---@param overlay beat.OverlayInstance
---@param window wonderland.RenderWindow
---@return wonderland.Element
function equalizerRename.view(app, overlay, window)
	local state = overlay.state --[[@as beat.EqualizerRenameState]]
	local name = state.name
	local theme = app.services.appearance.theme
	local width = math.min(theme:px(340), window.width - theme:px(32))
	local padding = theme:px(16)
	local height = theme:px(220)
	local panel = div()
	:style(sty():w(width):h(height):column():pad(padding):gap(theme:px(10))
	:radius(theme:radius("md")):bg(theme:color("elevated"))
	:border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(14), theme:px(36), "#00000099"))
	:onClick({ type = "keep"})
	:children({
	text("Rename preset"):style(theme:s():text(theme:type("lg")):weight("bold")
	:fg(theme:color("text"))),
	field.view(app, {
	name = "equalizerPresetName",
	value = state.draft,
	placeholder = "Preset name",
	oninput = function(value) return { type = "equalizerEditDraft", value = value} end,
	onsubmit = function() return { type = "saveEqualizerPresetRename", name = name, value = state.draft} end,
	}),
	div():style(sty():row():h(theme:px(32)):gap(theme:px(8)):align("center")
	:justify("end")):children({
	button.view(app, {
	label = "Cancel",
	onClick = { type = "cancelEqualizerPresetRename"},
	height = theme:px(30),
	width = theme:px(80),
	}),
	button.view(app, {
	label = "Save",
	onClick = { type = "saveEqualizerPresetRename", name = name, value = state.draft},
	primary = true,
	height = theme:px(30),
	width = theme:px(74),
	}),
	}),
	button.view(app, {
	label = "Delete preset",
	onClick = { type = "deleteEqualizerPreset", name = name},
	height = theme:px(30),
	width = width - padding * 2,
	}),
	})

	return div()
	:style(sty():size(window.width, window.height):offset(0, 0):z(132)
	:column():align("center"):justify("center")
	:bg(theme:color("overlay"))):onClick({ type = "dismiss"})
	:children({ panel})
end

return equalizerRename
