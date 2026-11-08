-- The plugins page: what the plugins folder holds, and a check box for each plugin in it. Beat's own
-- built-in plugins are not listed: they are how beat is made, not something a listener chooses.
-- Nothing here loads or unloads anything. A check box records what the next start should load --
-- plugins are part of the app from its first frame, so changing them means starting it again --
-- and the row says so until then.
local wonderland = require("wonderland")
local path = require("path")
local button = require("beat.app.components.button")
local icon = require("beat.app.components.icon")
local iconButton = require("beat.app.components.icon_button")
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

local STATE = {
	loaded = { label = "Loaded", tone = "success" },
	off = { label = "Off", tone = "muted" },
	failed = { label = "Failed", tone = "danger" },
	["doesn't fit"] = { label = "Doesn't fit", tone = "danger" },
	["switched off"] = { label = "Switched off", tone = "danger" },
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
---@param entry beat.PluginStatus
---@param width number # The card's inner width, which the name and the check box share
local function row(app, entry, width)
	local theme = app.services.appearance.theme
	local values = app.services.settings.values
	local state = STATE[entry.state] or STATE.failed
	local file = keyOf(entry)
	local textWidth = width - (file ~= nil and (theme:px(CHECK_TARGET) + theme:px(10)) or 0)

	local children = {
		div():style(sty():column():w(math.max(theme:px(80), textWidth)):h(theme:px(40))
		:gap(theme:px(2)):justify("center")):children({
			text(entry.name):style(theme:s():wrel(1.0):text(theme:type("sm")):weight("semibold")
			:fg(theme:color("text")):ellipsis()),
			text(detail(entry, values)):style(theme:s():wrel(1.0):text(theme:type("xs"))
			:fg(theme:color(state.tone)):ellipsis()),
		}),
	}
	if file ~= nil then
		local on = not isOff(values, entry)
		local size = theme:px(CHECK)
		local box = sty():size(size, size):radius(theme:radius("sm")):align("center"):justify("center")
		if on then
			box:bg(theme:color("accent")):border(theme:px(1), theme:color("accent"))
		else
			box:border(theme:px(1.5), theme:color("muted"))
		end
		children[#children + 1] = div()
		:style(sty():size(theme:px(CHECK_TARGET), theme:px(CHECK_TARGET)):align("center"):justify("center"))
		:onClick({ type = "pluginEnabled", file = file, enabled = not on})
		:children({
			div():style(box):children(on
			and icon.view(app, { name = "check", size = theme:px(14), colour = theme.accentInk })
			or div()),
		})
	end

	return div():style(sty():row():wrel(1.0):h(theme:px(ROW)):gap(theme:px(10)):align("center"))
	:children(children)
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

---@param app beat.App
---@param page beat.PageInstance
---@param window wonderland.RenderWindow
---@return wonderland.Element
function plugins.view(app, page, window)
	local theme = app.services.appearance.theme
	local narrow = window.width < 560
	local inner = metrics.contentWidth(app, window.width) - theme:px(PAD) * 2 - theme:px(2)

	local rows = {}
	for _, entry in ipairs(outsidePlugins(app)) do rows[#rows + 1] = row(app, entry, inner) end
	if #rows == 0 then
		rows[1] = div():style(sty():row():wrel(1.0):h(theme:px(ROW)):align("center")):children({
			text("No plugins yet. Put one in the plugins folder; the folder button opens it.")
			:style(theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()),
		})
	end

	-- The folder is where a plugin is installed, so it is opened from the list it fills.
	local header = div():style(sty():row():wrel(1.0):h(theme:px(32)):align("center")
	:justify("space-between")):children({
		text("Installed"):style(theme:s():text(theme:type("lg")):weight("bold"):fg(theme:color("text"))),
		iconButton.view(app, { name = "folder", size = theme:px(32), onClick = { type = "openPluginsFolder"} }),
	})
	local content = {
		header,
		text("Plugins are files made with lde bundle. Changes apply after a restart.")
		:style(theme:s():wrel(1.0):h(theme:px(20)):text(theme:type("sm")):fg(theme:color("muted"))
		:ellipsis()),
	}
	for _, item in ipairs(rows) do content[#content + 1] = item end

	-- Every child is followed by a gap but the last: the header, the line under it, and the rows.
	local cardHeight = PAD * 2 + 2 + 32 + 20 + #rows * ROW + (#content - 1) * GAP
	local card = div():style(sty():column():wrel(1.0):h(theme:px(cardHeight)):gap(theme:px(GAP))
	:pad(theme:px(PAD)):radius(theme:radius("md")):bg(theme:color("surface"))
	:border(theme:px(1), theme:color("border"))):children(content)

	return div():style(sty():column():wrel(1.0):h(theme:px(32 + 16 + cardHeight)):gap(theme:px(16)))
	:children({
		div():style(sty():row():wrel(1.0):h(theme:px(32)):align("center"):justify("space-between"))
		:children({
			text("Plugins"):style(theme:s():text(theme:type("xxl")):weight("bold"):fg(theme:color("text"))),
			button.view(app, {
				label = "Back to settings",
				onClick = { type = "navigate", page = { kind = "settings"}},
				height = theme:px(32),
				width = theme:px(narrow and 160 or 140),
			}),
		}),
		card,
	})
end

return plugins
