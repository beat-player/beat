-- Renaming a saved equalizer preset. The preset is named in its field and deleted from the same
-- dialog, so a name that is no longer wanted is not a trip through the settings.
local wonderland = require("wonderland")
local core = require("beat-core")
local render = require("beat.app.ui")
local equalizer = require("beat.app.overlays.equalizer")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.EqualizerRenameState
---@field name string # The preset as it is named now
---@field draft string

---@type beat.OverlaySurface
local equalizerRename = {}

---@param params { name: string? }
function equalizerRename.new(app, params)
	local preset = equalizer.find(app, params.name)
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

function equalizerRename.update(app, overlay, message)
	local state = overlay.state --[[@as beat.EqualizerRenameState]]
	local kind = message.type
	if kind == "equalizerEditDraft" then
		state.draft = message.value or ""
		app:refresh()
	elseif kind == "cancelEqualizerPresetRename" then
		app:close(overlay)
	elseif kind == "saveEqualizerPresetRename" then
		local oldName = state.name
		local newName = state.draft:match("^%s*(.-)%s*$")
		if newName == "" then
			app.services.toasts:show("Choose a preset name", "error")
		elseif not equalizer.nameFree(app, oldName, newName) then
			app.services.toasts:show("Choose a preset name that is not already used", "error")
		else
			local found
			for _, preset in ipairs(app.services.settings.values.equalizerCustomPresets) do
					if preset.name == oldName then found = preset end
				end
			if found ~= nil then
				found.name = newName
				if app.services.settings.values.equalizerPreset == oldName then
					app.services.settings.values.equalizerPreset = newName
				end
				app:close(overlay)
				app.services.settings:changed()
			end
		end
	elseif kind == "deleteEqualizerPreset" then
		local name = message.name or state.name
		local found
		for at, preset in ipairs(app.services.settings.values.equalizerCustomPresets) do
				if preset.name == name then found = at; break end
			end
		if found ~= nil then
			table.remove(app.services.settings.values.equalizerCustomPresets, found)
			if app.services.settings.values.equalizerPreset == name then
				app.services.settings.values.equalizerPreset = "flat"
				app.services.settings.values.equalizerGains = core.equalizer.presetGains("flat")
				app.services.playback.player:setEqualizer(core.equalizer.bands(app.services.settings.values.equalizerGains))
			end
			app:close(overlay)
			app.services.settings:changed()
		end
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
	render.field(app, "equalizerPresetName", state.draft, "Preset name",
	function(value) return { type = "equalizerEditDraft", value = value} end,
	function() return { type = "saveEqualizerPresetRename"} end),
	div():style(sty():row():h(theme:px(32)):gap(theme:px(8)):align("center")
	:justify("end")):children({
	render.button(app, "Cancel", { type = "cancelEqualizerPresetRename"},
	{ height = theme:px(30), width = theme:px(80)}),
	render.button(app, "Save", { type = "saveEqualizerPresetRename"},
	{ primary = true, height = theme:px(30), width = theme:px(74)}),
	}),
	render.button(app, "Delete preset", { type = "deleteEqualizerPreset", name = name},
	{ height = theme:px(30), width = width - padding * 2}),
	})

	return div()
	:style(sty():size(window.width, window.height):offset(0, 0):z(132)
	:column():align("center"):justify("center")
	:bg(theme:color("overlay"))):onClick({ type = "dismiss"})
	:children({ panel})
end

return equalizerRename
