-- The plugins page: beat's own plugins and the ones in the plugins folder, in one list each, with a
-- switch for the plugins that can be off. Nothing here loads or unloads anything. A switch records
-- what the next start should load -- plugins are part of the app from its first frame, so changing
-- them means starting it again -- and the row says so until then.
local wonderland = require("wonderland")
local path = require("path")
local ui = require("beat-ui")
local metrics = require("beat.app.components.helpers.metrics")
local measure = require("beat.app.components.helpers.measure")
local settingsList = require("beat.app.components.settings_list")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

-- A plugin's settings card padding, and the space between its title and the plugin's own view: the
-- card's height is worked out from them.
local PAD = 18
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

--- The line under the name: what state it is in, and anything else worth knowing. Who made it
--- sits next to the name as the row's badge instead, and a pending switch has its own note beside
--- the switch, so neither is repeated here.
---@param entry beat.PluginStatus
---@return string
local function meta(entry)
	local state = STATE[entry.state] or STATE.failed
	local parts = {}
	parts[#parts + 1] = state.label
	local key = keyOf(entry)
	if key ~= nil and not entry.builtin then parts[#parts + 1] = key end
	if entry.reason ~= nil then parts[#parts + 1] = entry.reason end
	return table.concat(parts, " · ")
end

--- The one line under a plugin's name: what state it is in, and what it adds.
---@param entry beat.PluginStatus
---@return string
local function describe(entry)
	local line = meta(entry)
	if entry.description ~= nil then line = line .. " · " .. entry.description end
	return line
end

--- The small badge a row shows after its name: its version and who made it, in faint small text.
--- A plugin that says neither has no badge.
---@param app beat.App
---@param entry beat.PluginStatus
---@return wonderland.Element?
---@return number?
local function pluginBadge(app, entry)
	local parts = {}
	if entry.version ~= nil then parts[#parts + 1] = "v" .. entry.version end
	if entry.author ~= nil then parts[#parts + 1] = "by " .. entry.author end
	if #parts == 0 then return nil, nil end
	local theme = app.services.appearance.theme
	local label = table.concat(parts, " · ")
	local element = text(label):style(theme:s():text(theme:type("xs")):fg(theme:color("faint")))
	local measured = measure.width(app, label, theme:s():text(theme:type("xs")):fg(theme:color("faint")))
	return element, (measured ~= nil and (measured + 1)) or theme:px(40)
end

--- A plugin's row: its name with its version and maker after it, what it is and does underneath,
--- and on the right either the switch that turns it off or a badge saying it cannot be switched.
---@param app beat.App
---@param entry beat.PluginStatus
---@param width number # The settings column's width
---@param core boolean? # Drawn quieter, with the badge that says why it has no switch
---@return beat.components.SettingsItem
local function entryRow(app, entry, width, core)
	local theme = app.services.appearance.theme
	local values = app.services.settings.values
	local key = keyOf(entry)
	---@type beat.components.SettingsRowProps
	local props = {
		label = entry.name,
		description = describe(entry),
		width = width,
		dim = core
	}
	local badge, badgeWidth = pluginBadge(app, entry)
	if badge ~= nil then
		props.badge = badge
		props.badgeWidth = badgeWidth
	end
	if core then
		local coreBadge, coreBadgeWidth = settingsList.badge(app, "Core")
		props.control = coreBadge
		props.controlWidth = coreBadgeWidth
		props.controlHeight = theme:px(20)
	elseif key ~= nil and not entry.required then
		local toggle, toggleWidth = settingsList.toggle(app, {
			on = not isOff(values, entry),
			onClick = { type = "pluginEnabled", file = key, enabled = isOff(values, entry) }
		})
		if pending(entry, values) ~= nil then
			-- The switch has already been recorded, but this app was built before it: say so where
			-- the switch is, since that is what someone looking at it just pressed.
			local label = "Needs restart"
			local gap = theme:px(10)
			local noteWidth = math.ceil(measure.width(app, label, theme:s():text(theme:type("xs")):weight("semibold")) or theme:px(72)) + 1
			local controlWidth = noteWidth + gap + toggleWidth
			props.control = div()
				:style(sty():row():w(controlWidth):h(theme:px(32)):gap(gap):align("center"))
				:children({
					text(label):style(
						theme:s():w(noteWidth):text(theme:type("xs")):weight("semibold"):fg(theme:color("warning"))
					),
					toggle
				})
			props.controlWidth = controlWidth
		else
			props.control = toggle
			props.controlWidth = toggleWidth
		end
	end
	return settingsList.row(app, props)
end

--- The installed list's row when there is nothing in the plugins folder.
---@param app beat.App
---@param width number
---@return beat.components.SettingsItem
local function noPluginsRow(app, width)
	return settingsList.row(app, {
		label = "No plugins installed",
		description = "Put a plugin file in the plugins folder, then restart beat.",
		width = width
	})
end

--- The row that opens the plugins folder.
---@param app beat.App
---@param ctx beat.ui.Context
---@param width number
---@return beat.components.SettingsItem
local function folderRow(app, ctx, width)
	local theme = app.services.appearance.theme
	local button = ui.button(
		ctx,
		{
			label = "Open folder",
			onClick = { type = "openPluginsFolder" },
			height = theme:px(32),
			width = theme:px(120)
		}
	)
	return settingsList.row(app, {
		label = "Plugins folder",
		description = "Where beat looks for plugin files",
		control = button,
		controlWidth = theme:px(120),
		controlHeight = theme:px(32),
		width = width
	})
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

--- The banner under the title when a switch is waiting for the next start, with the button that
--- starts it again now. Returns the element and the height it takes in the page.
---@param app beat.App
---@param ctx beat.ui.Context
---@param width number
---@return wonderland.Element
---@return number
local function restartBanner(app, ctx, width)
	local theme = app.services.appearance.theme
	local padY = theme:px(12)
	local padX = theme:px(16)
	local buttonWidth = theme:px(96)
	local buttonHeight = theme:px(32)
	local gap = theme:px(12)
	local textHeight = math.floor(theme:type("sm") * 1.4)
	local height = padY * 2 + math.max(textHeight, buttonHeight)
	local textWidth = math.max(theme:px(80), width - padX * 2 - buttonWidth - gap)

	local button = ui.button(
		ctx,
		{
			label = "Restart",
			variant = "primary",
			onClick = { type = "restartApp" },
			height = buttonHeight,
			width = buttonWidth
		}
	)
	local element = div()
		:style(
			sty()
				:row():w(width):h(height):pad(padY, padX, padY, padX):gap(gap):align("center"):justify("space-between")
				:radius(theme:radius("md")):bg(theme:color("warning", 0.12))
		)
		:children({
			text("Restart beat to apply plugin changes"):style(
				theme:s():w(textWidth):h(textHeight):text(theme:type("sm")):fg(theme:color("text")):ellipsis()
			),
			button
		})
	return element, height
end

---@param app beat.App
---@param page beat.PageInstance
---@param window wonderland.RenderWindow
---@return wonderland.Element
function plugins.view(app, page, window)
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local mobile = metrics.mobile(app, window.width)
	local column = settingsList.columnWidth(app, metrics.contentWidth(app, window.width))
	local titleHeight = math.floor(theme:type("xxl") * 1.25)
	local gap = theme:px(28)

	-- The three lists: the built-ins that cannot be off, the built-ins that can, and the plugins in
	-- the folder.
	local core, optional = {}, {}
	for _, entry in ipairs(builtinPlugins(app)) do
		if entry.required or keyOf(entry) == nil then
			core[#core + 1] = entry
		else
			optional[#optional + 1] = entry
		end
	end
	local installed = outsidePlugins(app)

	-- A switch is only real on the next start, so the page says when one is waiting for it.
	local restarting = false
	for _, entry in ipairs(app.pluginStates) do
		if pending(entry, app.services.settings.values) ~= nil then
			restarting = true
			break
		end
	end

	local children = {}
	local totalHeight = titleHeight

	local title = text("Plugins"):style(
		theme:s():h(titleHeight):text(theme:type("xxl")):weight("bold"):fg(theme:color("text"))
	)
	if mobile then
		children[#children + 1] = title
	else
		local back = ui.button(
			ctx,
			{
				label = "Back to settings",
				onClick = { type = "navigate", page = { kind = "settings" } },
				height = theme:px(32),
				width = theme:px(140)
			}
		)
		children[#children + 1] = div()
			:style(sty():row():w(column):h(titleHeight):align("center"):justify("space-between"))
			:children({ title, back })
	end

	if restarting then
		local banner, bannerHeight = restartBanner(app, ctx, column)
		children[#children + 1] = banner
		totalHeight += gap + bannerHeight
	end

	---@param heading string
	---@param rows beat.components.SettingsItem[]
	local function addGroup(heading, rows)
		if #rows == 0 then return end
		local element, height = settingsList.group(app, { title = heading, rows = rows, width = column })
		children[#children + 1] = element
		totalHeight += gap + height
	end

	local coreRows = {}
	for _, entry in ipairs(core) do
		coreRows[#coreRows + 1] = entryRow(app, entry, column, true)
	end
	addGroup("Core plugins", coreRows)

	local optionalRows = {}
	for _, entry in ipairs(optional) do
		optionalRows[#optionalRows + 1] = entryRow(app, entry, column)
	end
	addGroup("Built-in", optionalRows)

	local installedRows = {}
	for _, entry in ipairs(installed) do
		installedRows[#installedRows + 1] = entryRow(app, entry, column)
	end
	if #installed == 0 then installedRows[1] = noPluginsRow(app, column) end
	installedRows[#installedRows + 1] = folderRow(app, ctx, column)
	addGroup("Installed", installedRows)

	-- Below the lists, one card for each loaded plugin that asked for settings. The card fills the
	-- column, and its view gets the room inside the card's padding.
	local inner = column - theme:px(PAD) * 2
	for _, entry in ipairs(app.registry:settings()) do
		local card, height = settingsCard(app, ctx, entry, inner)
		if card ~= nil then
			children[#children + 1] = card
			totalHeight += gap + height
		end
	end

	local body = div():style(sty():column():w(column):h(totalHeight):gap(gap)):children(children)
	app.services.scroll:setLimit(app:pageKey(), metrics.pageScrollLimit(app, window, totalHeight))

	if mobile then return body end
	return div()
		:style(sty():row():wrel(1.0):h(totalHeight):justify("center"))
		:children({ body })
end

return plugins
