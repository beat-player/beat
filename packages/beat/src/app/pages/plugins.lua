-- The plugins page: beat's own plugins and the ones in the plugins folder, in one list each, with a
-- switch for the plugins that can be off. Nothing here loads or unloads anything. A switch records
-- what the next start should load -- plugins are part of the app from its first frame, so changing
-- them means starting it again -- and the row says so until then.
local wonderland = require("wonderland")
local path = require("path")
local ui = require("beat-ui")
local metrics = require("beat.app.components.helpers.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

-- The card's padding, and the gap between its rows, in unscaled pixels: the row widths and the
-- card's height are worked out from them, so that a switch sits inside the card's edge.
local PAD = 18
local GAP = 8
-- A row has a name and version, who made it and what state it is in, and its one-line description.
-- A phone gets the taller row so a finger has something to hit.
local ROW = 56
local ROW_PHONE = 64
-- The line under the section title.
local INTRO = 20
-- The check box, and the larger square around it a click lands in.
local CHECK = 20
local CHECK_TARGET = 32
local CHECK_TARGET_PHONE = 44
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

--- The key a switch for this entry acts on. A built-in is named by its plugin name; a plugin from
--- the folder by its file name, which is what the loader reads before the file runs. A plugin a
--- caller supplied has neither and cannot be switched off here.
---@param entry beat.PluginStatus
---@return string?
local function keyOf(entry)
	if entry.builtin then return entry.name end
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

--- What a switch changed that the running app has not taken yet, or nil when there is nothing
--- waiting for the next start.
---@param entry beat.PluginStatus
---@param values beat.Settings
local function pending(entry, values)
	local off = isOff(values, entry)
	if entry.state == "off" and not off then return "on after restart" end
	if (entry.state == "loaded" or entry.state == "switched off") and off then return "off after restart" end
	return nil
end

--- The line under the name: who made it, what state it is in, and anything else worth knowing.
---@param entry beat.PluginStatus
---@param values beat.Settings
---@return string
local function meta(entry, values)
	local state = STATE[entry.state] or STATE.failed
	local parts = {}
	if entry.author ~= nil then parts[#parts + 1] = "by " .. entry.author end
	parts[#parts + 1] = state.label
	local key = keyOf(entry)
	if key ~= nil and not entry.builtin then parts[#parts + 1] = key end
	if entry.reason ~= nil then parts[#parts + 1] = entry.reason end
	local waiting = pending(entry, values)
	if waiting ~= nil then parts[#parts + 1] = waiting end
	return table.concat(parts, " · ")
end

---@param app beat.App
---@param ctx beat.ui.Context
---@param entry beat.PluginStatus
---@param width number # The card's inner width, which the name and the switch share
---@param phone boolean
local function row(app, ctx, entry, width, phone)
	local theme = app.services.appearance.theme
	local values = app.services.settings.values
	local state = STATE[entry.state] or STATE.failed
	local key = keyOf(entry)
	-- A built-in the rest of the app asks for by name has no switch: there is no app to come back
	-- to if it is off.
	local switchable = key ~= nil and not entry.required
	local target = theme:px(phone and CHECK_TARGET_PHONE or CHECK_TARGET)
	local textWidth = math.max(theme:px(80), width - (switchable and target + theme:px(10) or 0))

	local nameRow = {
		text(entry.name):style(
			theme:s():wrel(1.0):text(theme:type("sm")):weight("semibold"):fg(theme:color("text")):ellipsis()
		)
	}
	if entry.version ~= nil then
		nameRow[#nameRow + 1] = text("v" .. entry.version):style(
			theme:s():text(theme:type("xs")):fg(theme:color("faint"))
		)
	end

	local lines = {
		div():style(sty():row():w(textWidth):h(theme:px(20)):gap(theme:px(6)):align("center")):children(nameRow),
		text(meta(entry, values)):style(
			theme:s():w(textWidth):text(theme:type("xs")):fg(theme:color(state.tone)):ellipsis()
		)
	}
	if entry.description ~= nil then
		lines[#lines + 1] = text(entry.description):style(
			theme:s():w(textWidth):text(theme:type("xs")):fg(theme:color("muted")):ellipsis()
		)
	end

	local children = {
		div():style(sty():column():w(textWidth):hrel(1.0):justify("center"):gap(theme:px(2))):children(lines)
	}
	if switchable then
		local on = not isOff(values, entry)
		children[#children + 1] = ui.checkbox(
			ctx,
			{
				checked = on,
				onClick = { type = "pluginEnabled", file = key, enabled = not on },
				size = theme:px(CHECK),
				target = target
			}
		)
	end

	return div()
		:style(sty():row():wrel(1.0):h(theme:px(phone and ROW_PHONE or ROW)):gap(theme:px(10)):align("center"))
		:children(children)
end

--- One section: its title, the line under it, and a row for every plugin it holds -- or the
--- caller's message when it holds none.
---@param app beat.App
---@param ctx beat.ui.Context
---@param title string
---@param intro string
---@param entries beat.PluginStatus[]
---@param width number # The card's inner width
---@param phone boolean
---@param action wonderland.Element?
---@param empty wonderland.Element? # Drawn instead of the rows when there are none
---@return wonderland.Element
---@return number height
local function section(app, ctx, title, intro, entries, width, phone, action, empty)
	local theme = app.services.appearance.theme
	local rowHeight = theme:px(phone and ROW_PHONE or ROW)

	local content = {
		text(intro):style(
			theme:s():wrel(1.0):h(theme:px(INTRO)):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()
		)
	}
	for _, entry in ipairs(entries) do
		content[#content + 1] = row(app, ctx, entry, width, phone)
	end
	if #entries == 0 and empty ~= nil then content[#content + 1] = empty end
	local rowCount = math.max(#entries, empty ~= nil and 1 or 0)
	local height = theme:px(PAD * 2)
		+ (action ~= nil and theme:px(32) or theme:px(24))
		+ theme:px(GAP)
		+ theme:px(INTRO)
		+ theme:px(GAP)
		+ rowCount * rowHeight
		+ math.max(0, rowCount - 1) * theme:px(GAP)

	local card = ui.card(
		ctx,
		{
			title = title,
			action = action,
			children = content,
			height = height,
			padding = theme:px(PAD),
			gap = theme:px(GAP)
		}
	)
	return card, height
end

---@param app beat.App
---@param phone boolean
local function emptyRow(app, phone)
	local theme = app.services.appearance.theme
	return div()
		:style(sty():row():wrel(1.0):h(theme:px(phone and ROW_PHONE or ROW)):align("center"))
		:children(
			{
				text("No plugins yet. Put one in the plugins folder; the folder button opens it.")
					:style(theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis())
			}
		)
end

---@param app beat.App
---@return beat.PluginStatus[]
local function builtinPlugins(app)
	local found = {}
	for _, entry in ipairs(app.pluginStates) do
		if entry.builtin then found[#found + 1] = entry end
	end
	return found
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
	local phone = metrics.mobile(app, window.width)
	local inner = metrics.contentWidth(app, window.width) - theme:px(PAD) * 2 - theme:px(2)

	local builtCard, builtHeight = section(
		app,
		ctx,
		"Built-in",
		"Beat's own plugins. They are how the app is made; the optional ones can be switched off.",
		builtinPlugins(app),
		inner,
		phone,
		nil,
		nil
	)

	local installed = outsidePlugins(app)
	local installedCard, installedHeight = section(
		app,
		ctx,
		"Installed",
		"Plugins in the plugins folder. A change applies after a restart.",
		installed,
		inner,
		phone,
		ui.iconButton(ctx, { name = "folder", size = theme:px(32), onClick = { type = "openPluginsFolder" } }),
		emptyRow(app, phone)
	)

	-- Below the two lists, one card for each loaded plugin that asked for settings. The card is
	-- drawn at the height the plugin's own `height` said, and its view gets the same inner width
	-- as the plugin rows.
	local cards = { builtCard, installedCard }
	local cardsHeight = builtHeight + theme:space(16) + installedHeight
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
