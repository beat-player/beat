-- The in-app folder browser: where a first launch picks its music folder when the desktop's own
-- dialog is not the way in, and where a typed or pasted path is opened.
local wonderland = require("wonderland")
local fs = require("fs")
local path = require("path")
local ui = require("beat-ui")
local button = require("beat.app.components.button")
local metrics = require("beat.app.components.helpers.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local HOME = os.getenv("HOME") or os.getenv("USERPROFILE") or "/"

---@class beat.FoldersState
---@field path string
---@field entries { name: string, path: string }[]
---@field error string?

---@type beat.PageSurface
local folders = {}

--- Lists the folders inside `pathname`, sorted by name, leaving out hidden ones.
---@param app beat.App
---@param state beat.FoldersState
---@param pathname string
local function read(app, state, pathname)
	if pathname:sub(1, 1) == "~" then pathname = HOME .. pathname:sub(2) end
	state.path = path.normalize(pathname)
	state.entries = {}
	state.error = nil
	app.services.scroll:reset("folders")

	local iterator = fs.readdir(state.path)
	if iterator == nil then
		state.error = "Cannot read this folder"
		return
	end

	for entry in iterator do
			if entry.type == "dir" and entry.name:sub(1, 1) ~= "." then
				state.entries[#state.entries + 1] = { name = entry.name, path = path.join(state.path, entry.name)}
			end
		end
	table.sort(state.entries, function(a, b) return a.name:lower() < b.name:lower() end)
end

function folders.new(app)
	---@type beat.FoldersState
	local state = { path = HOME, entries = {}}
	read(app, state, app.services.settings.values.root or HOME)
	return state
end

function folders.update(app, page, message)
	local state = page.state --[[@as beat.FoldersState]]
	local kind = message.type
	if kind == "folderOpen" then
		read(app, state, message.path)
	elseif kind == "folderGo" then
		if type(message.path) ~= "string" or message.path == "" then return true end
		read(app, state, message.path)
	elseif kind == "folderUp" then
		read(app, state, path.dirname(state.path))
	elseif kind == "folderSelect" then
		app:act({ type = "startScan", root = message.path or state.path})
		return true
	elseif kind == "cancelFolders" then
		app:back()
		return true
	else
		return false
	end
	app:refresh()
	return true
end

function folders.view(app, page, window)
	local state = page.state --[[@as beat.FoldersState]]
	local theme = app.services.appearance.theme
	local mobile = metrics.mobile(app, window.width)
	local pad = metrics.pad(app, window.width)
	local rows = {}

	local choose = button.view(app, {
	label = "Choose folder…",
	onClick = { type = "chooseFolder"},
	primary = true,
	height = theme:px(30),
	width = theme:px(142),
	})
	local up = button.view(app, {
	label = "Up",
	onClick = { type = "folderUp"},
	height = theme:px(30),
	width = theme:px(48),
	})
	local select = button.view(app, {
	label = "Select this folder",
	onClick = { type = "folderSelect", path = state.path},
	height = theme:px(30),
	width = theme:px(150),
	})
	local cancel = app.services.library.current ~= nil and button.view(app, {
	label = "Cancel",
	onClick = { type = "cancelFolders"},
	height = theme:px(30),
	width = theme:px(80),
	}) or nil

	if mobile then
		local second = { select}
		if cancel ~= nil then second[#second + 1] = cancel end
		rows[#rows + 1] = div():style(sty():column():h(theme:px(76)):gap(theme:px(8))):children({
		div():style(sty():row():h(theme:px(30)):gap(theme:px(8)):align("center")):children({ choose, up}),
		div():style(sty():row():h(theme:px(30)):gap(theme:px(8)):align("center")):children(second),
		})
	else
		local actions = { choose, up, select}
		if cancel ~= nil then actions[#actions + 1] = cancel end
		rows[#rows + 1] = div():style(sty():row():h(theme:px(38)):gap(theme:px(8)):align("center"))
		:children(actions)
	end

	for _, entry in ipairs(state.entries) do
			rows[#rows + 1] = div()
			:style(sty():row():h(theme:px(44)):gap(theme:px(10)):align("center"):radius(theme:radius("sm")))
			:hover(sty():row():h(theme:px(44)):gap(theme:px(10)):align("center"):radius(theme:radius("sm"))
			:bg(theme:color("hover")))
			:onClick({ type = "folderOpen", path = entry.path})
			:children({
			ui.icons.element("folder", theme:px(20), theme:color("muted")),
			text(entry.name):style(theme:s():text(theme:type("base")):fg(theme:color("text"))),
			})
		end

	local content = div():style(sty():column():wrel(1.0):h("auto"):gap(theme:space(10)))
	content:children({
	text(mobile and "Choose a folder" or "Choose your music folder"):style(theme:s():wrel(1.0)
	:text(theme:type(mobile and "xl" or "xxl")):weight("bold"):fg(theme:color("text")):ellipsis()),
	text(mobile and "Everything is scanned locally."
	or "Everything under it is scanned. Nothing is uploaded anywhere."):style(
	theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()
	),
	text(state.path):style(theme:s():wrel(1.0):h(theme:px(24)):pad(theme:px(5), theme:px(8),
	theme:px(5), theme:px(8)):radius(theme:radius("sm")):bg(theme:color("surface"))
	:text(theme:type("xs")):fg(theme:color("faint")):ellipsis())
	:input({
	name = "folderPath",
	value = state.path,
	oninput = function() end,
	onsubmit = function(value) return { type = "folderGo", path = value} end,
	}),
	})
	if state.error ~= nil then
		content:children(text(state.error):style(
		theme:s():text(theme:type("xs")):fg(theme:color("danger"))
		))
	end
	content:children(div():style(sty():column():wrel(1.0):h(theme:px(320)):pad(0, 0, 0, 0)
	:bar(theme:px(8), theme:px(40), theme:color("faint")))
	:scroll(app.services.scroll:offset("folders"))
	:onScroll(function(by, to)
		return { type = "scroll", key = app:pageKey(), by = by, to = to}
	end):children(rows))

	return div():style(sty():column():wrel(1.0):h(theme:px(540)):pad(theme:space(20), pad, theme:space(20), pad)
	:gap(theme:space(16))):children({ content})
end

return folders
