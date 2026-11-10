-- The plugins page: what the plugins folder holds, and a check box for each plugin in it. Beat's own
-- built-in plugins are not listed: they are how beat is made, not something a listener chooses.
-- Nothing here loads or unloads anything. A check box records what the next start should load --
-- plugins are part of the app from its first frame, so changing them means starting it again --
-- and the row says so until then.
local wonderland = require("wonderland")
local path = require("path")
local ui = require("beat-ui")
local metrics = require("beat.app.components.helpers.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

-- The card's padding, and the gap between its rows, in unscaled pixels: the row widths and the
-- card's height are worked out from them, so that a check box sits inside the card's edge.
local PAD = 18
local GAP = 8
local ROW = 44
-- The check box, and the larger square around it a click lands in.
local CHECK = 20
local CHECK_TARGET = 32
-- A settings card's title, and the space between it and the plugin's own view.
local SETTINGS_TITLE = 24

local STATE = {
	loaded = { label = "Loaded", tone = "success" },
	off = { label = "Off", tone = "muted" },
	failed = { label = "Failed", tone = "danger" },
	["doesn't fit"] = { label = "Doesn't fit", tone = "danger" },
	["switched off"] = { label = "Switched off", tone = "danger" }
}

---@type beat.PageSurface
local plugins = {}

--- The file name a check box for this entry acts on. A plugin from the folder has one; a plugin a
--- caller supplied does not, and cannot be switched off here.
---@param entry beat.PluginStatus
---@return string?
local function keyOf(entry)
	if entry.file == nil then return nil end
	return path.basename(entry.file)
end

---@param values beat.Settings
---@param entry beat.PluginStatus
---@return boolean
local function isOff(values, entry)
	local key = keyOf(entry)
	if key == nil then return false end
	for _, disabled in ipairs(values.disabledPlugins) do
		if disabled == key then return true end
	end
	return false
end

--- What a check box changed that the running app has not taken yet, or nil when there is nothing
--- waiting for the next start.
---@param entry beat.PluginStatus
---@param values beat.Settings
local function pending(entry, values)
	local off = isOff(values, entry)
	if entry.state == "off" and not off then return "on after restart" end
	if (entry.state == "loaded" or entry.state == "switched off") and off then return "off after restart" end
	return nil
end

---@param entry beat.PluginStatus
---@param values beat.Settings
local function detail(entry, values)
	local state = STATE[entry.state] or STATE.failed
	local parts = { state.label }
	if entry.version ~= nil then parts[#parts + 1] = "v" .. entry.version end
	parts[#parts + 1] = keyOf(entry) or entry.source
	if entry.reason ~= nil then parts[#parts + 1] = entry.reason end
	local waiting = pending(entry, values)
	if waiting ~= nil then parts[#parts + 1] = waiting end
	return table.concat(parts, " · ")
end

---@param app beat.App
---@param ctx beat.ui.Context
---@param entry beat.PluginStatus
---@param width number # The card's inner width, which the name and the check box share
local function row(app, ctx, entry, width)
	local theme = app.services.appearance.theme
	local values = app.services.settings.values
	local state = STATE[entry.state] or STATE.failed
	local file = keyOf(entry)
	local textWidth = width - (file ~= nil and (theme:px(CHECK_TARGET) + theme:px(10)) or 0)

	local children = {
		div()
			:style(sty():column():w(math.max(theme:px(80), textWidth)):h(theme:px(40)):gap(theme:px(2)):justify("center"))
			:children(
				{
					text(entry.name)
						:style(theme:s():wrel(1.0):text(theme:type("sm")):weight("semibold"):fg(theme:color("text")):ellipsis()),
					text(detail(entry, values))
						:style(theme:s():wrel(1.0):text(theme:type("xs")):fg(theme:color(state.tone)):ellipsis())
				}
			)
	}
	if file ~= nil then
		local on = not isOff(values, entry)
		children[#children + 1] = ui.checkbox(
			ctx,
			{
				checked = on,
				onClick = { type = "pluginEnabled", file = file, enabled = not on },
				size = theme:px(CHECK),
				target = theme:px(CHECK_TARGET)
			}
		)
	end

	return div():style(sty():row():wrel(1.0):h(theme:px(ROW)):gap(theme:px(10)):align("center")):children(children)
end

---@param app beat.App
---@return beat.PluginStatus[]
local function outsidePlugins(app)
	local found = {}
	for _, entry in ipairs(app.pluginStates) do
		if not entry.builtin then found[#found + 1] = entry end
	end
	return found
end

--- One plugin's settings card: its title and the view it returned, at the height it asked for.
--- A view or height that raises switches the plugin off the same way any other hook does, and the
--- card is left out of this frame.
---@param app beat.App
---@param uiCtx beat.ui.Context
---@param entry beat.PluginSettings
---@param width number # The inner width the plugin's view is given
---@return wonderland.Element?
---@return number height
local function settingsCard(app, uiCtx, entry, width)
	local theme = app.services.appearance.theme
	local plugin = entry.plugin

	---@type beat.PluginSettingsContext
	local ctx = {
		plugin = plugin.name,
		values = app.services.settings:plugin(plugin.name),
		width = width,
		set = |key, value| -> { type = "pluginSetting", plugin = plugin.name, key = key, value = value }
	}

	local okHeight, height = pcall(entry.height, app, ctx)
	if not okHeight then
		app.registry:disable(plugin, height)
		return nil, 0
	end
	if type(height) ~= "number" or height ~= height or height < 0 then
		app.registry:disable(plugin, "settings height must be a size")
		return nil, 0
	end

	local okView, view = pcall(entry.view, app, ctx)
	if not okView then
		app.registry:disable(plugin, view)
		return nil, 0
	end
	if view == nil then
		app.registry:disable(plugin, "settings view returned nothing")
		return nil, 0
	end

	local titleHeight = theme:px(SETTINGS_TITLE)
	local gap = theme:space(12)
	local cardHeight = theme:px(PAD * 2) + titleHeight + gap + height
	local card = ui.card(
		uiCtx,
		{
			title = entry.title,
			children = { view },
			height = cardHeight,
			padding = theme:px(PAD),
			gap = gap
		}
	)

	return card, cardHeight
end

---@param app beat.App
---@param page beat.PageInstance
---@param window wonderland.RenderWindow
---@return wonderland.Element
function plugins.view(app, page, window)
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local narrow = window.width < 560
	local inner = metrics.contentWidth(app, window.width) - theme:px(PAD) * 2 - theme:px(2)

	local rows = {}
	for _, entry in ipairs(outsidePlugins(app)) do rows[#rows + 1] = row(app, ctx, entry, inner) end
	if #rows == 0 then
		rows[1] = div()
			:style(sty():row():wrel(1.0):h(theme:px(ROW)):align("center"))
			:children(
				{
					text("No plugins yet. Put one in the plugins folder; the folder button opens it.")
						:style(theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis())
				}
			)
	end

	-- The folder is where a plugin is installed, so it is opened from the list it fills. Every
	-- child is followed by a gap but the last: the line under the title, and the rows.
	local content = {
		text("Plugins are files made with lde bundle. Changes apply after a restart.")
			:style(theme:s():wrel(1.0):h(theme:px(20)):text(theme:type("sm")):fg(theme:color("muted")):ellipsis())
	}
	for _, item in ipairs(rows) do content[#content + 1] = item end

	local cardHeight = PAD * 2 + 2 + 32 + 20 + #rows * ROW + (#content) * GAP
	local card = ui.card(
		ctx,
		{
			title = "Installed",
			action = ui.iconButton(
				ctx,
				{ name = "folder", size = theme:px(32), onClick = { type = "openPluginsFolder" } }
			),
			children = content,
			height = theme:px(cardHeight),
			padding = theme:px(PAD),
			gap = theme:px(GAP)
		}
	)

	-- Below the installed list, one card for each loaded plugin that asked for settings. The card
	-- is drawn at the height the plugin's own `height` said, and its view gets the same inner width
	-- as the installed rows.
	local cards = { card }
	local cardsHeight = theme:px(cardHeight)
	for _, entry in ipairs(app.registry:settings()) do
		local element, height = settingsCard(app, ctx, entry, inner)
		if element ~= nil then
			cards[#cards + 1] = element
			cardsHeight += theme:space(16) + height
		end
	end

	local stack = div()
		:style(sty():column():wrel(1.0):h(cardsHeight):gap(theme:space(16))):children(cards)

	return div()
		:style(sty():column():wrel(1.0):h(theme:px(32) + theme:space(16) + cardsHeight):gap(theme:space(16)))
		:children(
			{
				div()
					:style(sty():row():wrel(1.0):h(theme:px(32)):align("center"):justify("space-between"))
					:children(
						{
							text("Plugins"):style(theme:s():text(theme:type("xxl")):weight("bold"):fg(theme:color("text"))),
							ui.button(
								ctx,
								{
									label = "Back to settings",
									onClick = { type = "navigate", page = { kind = "settings" } },
									height = theme:px(32),
									width = theme:px(narrow and 160 or 140)
								}
							)
						}
					),
				stack
			}
		)
end

return plugins
