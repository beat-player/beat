-- The in-app folder browser: where the first launch picks its music folder when the desktop's own
-- dialog is not the way in, and where a typed or pasted path is opened. The first launch draws it in
-- the welcome card (components/onboarding.lua); the page it also is stays usable on its own.
local wonderland = require("wonderland")
local fs = require("fs")
local path = require("path")
local ui = require("beat-ui")
local cache = require("beat-ui.cache")
local metrics = require("beat.app.components.helpers.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local HOME = os.getenv("HOME") or os.getenv("USERPROFILE") or "/"

-- The messages that say the same thing every frame. A row's own messages are made when the folder
-- is read, since they carry its path.
local UP = { type = "folderUp" }
local CHOOSE = { type = "chooseFolder" }
local CANCEL = { type = "cancelFolders" }
local WELCOME = { type = "onboardingWelcome" }

---@class beat.FoldersState
---@field path string
---@field pathDraft string # What the path field holds, until Enter or a navigation replaces it
---@field entries { name: string, path: string, open: beat.Message }[]
---@field select beat.Message # Use this folder, with the path read here rather than built each frame
---@field step "welcome"|"folders"
---@field error string?

---@type beat.PageSurface
local folders = {}

-- The path field takes typing and answers Enter. It is handed the value it was typed, but its
-- submit handler is not, so the draft is read from the page the app is showing. Neither handler
-- needs the frame that drew it, so one pair is made for the app rather than a closure a frame.
---@class beat.FoldersPathHandlers
---@field input fun(value: string): any
---@field submit fun(): any

---@type table<beat.App, beat.FoldersPathHandlers>
local pathHandlers = setmetatable({}, { __mode = "k" })

---@param app beat.App
---@return beat.FoldersPathHandlers
local function pathHandler(app)
	local pair = pathHandlers[app]
	if pair == nil then
		pair = {
			---@param value string
			input = function(value)
				local state = app.page.state
				if state ~= nil then state.pathDraft = value end
			end,
			submit = function()
				local state = app.page.state
				return { type = "folderGo", path = state ~= nil and state.pathDraft or nil }
			end
		}
		pathHandlers[app] = pair
	end
	return pair
end

-- One scroll handler per app: it reads the page the frame drew, which the app already holds.
---@type table<beat.App, fun(by: number?, to: number?): any>
local scrollHandlers = setmetatable({}, { __mode = "k" })

---@param app beat.App
---@return fun(by: number?, to: number?): any
local function scrollHandler(app)
	local handler = scrollHandlers[app]
	if handler == nil then
		handler = |by, to| -> { type = "scroll", key = app:pageKey(), by = by, to = to }
		scrollHandlers[app] = handler
	end
	return handler
end

--- Lists the folders inside `pathname`, sorted by name, leaving out hidden ones.
---@param app beat.App
---@param state beat.FoldersState
---@param pathname string
local function read(app, state, pathname)
	if pathname:sub(1, 1) == "~" then pathname = HOME .. pathname:sub(2) end
	state.path = path.normalize(pathname)
	state.pathDraft = state.path
	state.entries = {}
	state.error = nil
	state.select = { type = "folderSelect", path = state.path }
	app.services.scroll:reset("folders")

	local iterator = fs.readdir(state.path)
	if iterator == nil then
		state.error = "Cannot read this folder"
		return
	end

	local entries = state.entries
	for entry in iterator do
		if entry.type == "dir" and entry.name:sub(1, 1) ~= "." then
			entries[#entries + 1] = {
				name = entry.name,
				path = path.join(state.path, entry.name),
				open = { type = "folderOpen", path = path.join(state.path, entry.name) }
			}
		end
	end
	table.sort(entries, |a, b| -> a.name:lower() < b.name:lower())
end

---@param app beat.App
function folders.new(app)
	---@type beat.FoldersState
	local state = {
		path = HOME,
		pathDraft = HOME,
		entries = {},
		select = { type = "folderSelect", path = HOME },
		-- A launch with no root is the first launch: it greets before it lists the folders. A page
		-- a saved route opens when a folder is already chosen goes straight to the browser.
		step = app.services.scan:needsFolder() and "welcome" or "folders"
	}
	read(app, state, app.services.settings.values.root or HOME)
	return state
end

---@param app beat.App
---@param page beat.PageInstance<beat.FoldersState>
---@param message beat.Message
function folders.update(app, page, message)
	local state = page.state
	if message.type == "folderOpen" then
		read(app, state, message.path)
	elseif message.type == "folderGo" then
		if type(message.path) ~= "string" or message.path == "" then return true end
		read(app, state, message.path)
	elseif message.type == "folderUp" then
		read(app, state, path.dirname(state.path))
	elseif message.type == "onboardingBrowse" then
		state.step = "folders"
	elseif message.type == "onboardingWelcome" then
		if not app.services.scan:needsFolder() then return true end
		state.step = "welcome"
	elseif message.type == "folderSelect" then
		app:act({ type = "startScan", root = message.path or state.path })
		return true
	elseif message.type == "cancelFolders" then
		app:back()
		return true
	else
		return false
	end
	app:refresh()
	return true
end

---@class beat.FoldersStyles
---@field section wonderland.StyleBuilder
---@field header wonderland.StyleBuilder
---@field title wonderland.StyleBuilder
---@field copy wonderland.StyleBuilder
---@field pathRow wonderland.StyleBuilder
---@field list wonderland.StyleBuilder
---@field group wonderland.StyleBuilder
---@field name wonderland.StyleBuilder
---@field empty wonderland.StyleBuilder
---@field emptyText wonderland.StyleBuilder
---@field emptyError wonderland.StyleBuilder
---@field footer wonderland.StyleBuilder
---@field footerColumn wonderland.StyleBuilder
---@field actions wonderland.StyleBuilder

--- Everything about the browser that only the width, the room it has and the theme decide. A
--- frame that scrolls or resizes hands the same values back, so it gets the same record.
---@param ctx beat.ui.Context
---@param width number
---@param sectionHeight number
---@param listHeight number
---@param rowHeight number
---@param headerHeight number
---@param titleHeight number
---@param copyHeight number
---@param mobile boolean
---@param actionsWidth number
---@param groupWidth number
---@param nameWidth number
---@return beat.FoldersStyles
local function folderStyles(ctx, width, sectionHeight, listHeight, rowHeight, headerHeight, titleHeight, copyHeight, mobile, actionsWidth, groupWidth, nameWidth)
	local footerHeight = mobile and (ctx:px(36) + ctx:space(8) + ctx:px(36)) or ctx:px(36)
	return {
		section = sty():w(width):h(sectionHeight):column():gap(ctx:space(16)),
		header = sty():w(width):h(headerHeight):column():gap(ctx:space(4)),
		title = ctx:s():w(width):h(titleHeight):text(ctx:type("xl")):weight("bold"):fg(ctx:color("text")):ellipsis(),
		copy = ctx:s():w(width):h(copyHeight):text(ctx:type("sm")):fg(ctx:color("muted")):ellipsis(),
		pathRow = sty():row():w(width):h(ctx:px(34)):gap(ctx:px(8)):align("center"),
		list = sty()
			:column():w(width):h(listHeight)
			:pad(ctx:px(6), ctx:px(16), ctx:px(6), ctx:px(16)):radius(ctx:radius("md")):bg(ctx:color("surface"))
			:border(ctx:px(1), ctx:color("border")):bar(ctx:px(8), ctx:px(40), ctx:color("faint")),
		group = sty():row():w(groupWidth):h(rowHeight):gap(ctx:px(10)):align("center"),
		name = ctx:s():w(nameWidth):text(ctx:type("base")):fg(ctx:color("text")):ellipsis(),
		empty = sty():row():w(width - ctx:px(32)):h(listHeight - ctx:px(12)):align("center"):justify("center"),
		emptyText = ctx:s():text(ctx:type("sm")):fg(ctx:color("faint")),
		emptyError = ctx:s():text(ctx:type("sm")):fg(ctx:color("danger")),
		footer = sty():row():w(width):h(footerHeight):gap(ctx:px(8)):align("center"):justify("space-between"),
		footerColumn = sty():column():w(width):h(footerHeight):gap(ctx:space(8)),
		actions = sty():row():w(actionsWidth):h(ctx:px(36)):gap(ctx:px(8)):align("center")
	}
end

--- The browser: the path in a well with a button to its parent, the folders under it in a group
--- card, and what can be done with the folder that is open. It fills the width it is given, which
--- the first-launch card and the page both know; when it is given a height, the list takes what
--- the rest of the step leaves.
---@param app beat.App
---@param page beat.PageInstance<beat.FoldersState>
---@param window wonderland.RenderWindow
---@param width number? # The room the browser has; a page in the shell is as wide as its body
---@param height number? # The room it must fill, or nil to be as tall as its list
---@return wonderland.Element element
---@return number height # What it takes, in whole rows
function folders.view(app, page, window, width, height)
	local state = page.state
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local mobile = metrics.mobile(app, window.width)
	width = math.max(theme:px(200), math.min(width or metrics.contentWidth(app, window.width), theme:px(560)))

	local rowHeight = theme:px(44)
	local sectionGap = theme:space(16)
	local titleHeight = math.floor(theme:type("xl") * 1.35)
	local copyHeight = math.floor(theme:type("sm") * 1.4)
	local headerHeight = titleHeight + theme:space(4) + copyHeight
	local pathHeight = theme:px(34)
	local footerHeight = mobile and (theme:px(36) + theme:space(8) + theme:px(36)) or theme:px(36)
	local chrome = headerHeight + pathHeight + footerHeight + sectionGap * 3

	local listHeight, sectionHeight
	if height ~= nil then
		-- Whole rows only: a row cut through its text at the bottom of the card reads as a fault,
		-- not as more to scroll to.
		local room = math.max(theme:px(132), height - chrome) - theme:px(12)
		listHeight = math.max(theme:px(100), math.floor(room / rowHeight) * rowHeight + theme:px(12))
		sectionHeight = chrome + listHeight
	else
		local room = math.max(theme:px(140), math.min(theme:px(300), window.height - theme:px(330))) - theme:px(12)
		listHeight = math.max(theme:px(100), math.floor(room / rowHeight) * rowHeight + theme:px(12))
		sectionHeight = chrome + listHeight
	end

	-- A page opened on its own has somewhere to go back to. In the first launch the way back is the
	-- welcome step, and there is no page under it to cancel to.
	local back = app.services.library.current ~= nil and CANCEL or (app.services.scan:needsFolder() and WELCOME or nil)

	-- A row child that states no width takes the whole row, siblings included, so the button group
	-- and every folder row are told their widths rather than left to fill.
	local chooseWidth = theme:px(140)
	local backWidth = theme:px(84)
	local backAndGap = back ~= nil and (backWidth + theme:px(8)) or 0
	local primaryWidth = mobile and width or math.min(theme:px(300), math.max(theme:px(128), width - chooseWidth - backAndGap - theme:px(16)))
	local actionsWidth = mobile and (backAndGap + chooseWidth) or (backAndGap + primaryWidth)
	local groupWidth = width - theme:px(32) - theme:px(16) - theme:px(8) - theme:px(16)
	local nameWidth = groupWidth - theme:px(20) - theme:px(10)

	local styles = cache.of(
		ctx,
		folderStyles,
		"folders",
		width,
		sectionHeight,
		listHeight,
		rowHeight,
		headerHeight,
		titleHeight,
		copyHeight,
		mobile,
		actionsWidth,
		groupWidth,
		nameWidth
	) --[[@as beat.FoldersStyles]]

	local upSize = theme:px(34)
	local fieldWidth = width - upSize - theme:px(8)
	local handlers = pathHandler(app)
	local pathRow = div():style(styles.pathRow):children({
		ui.field(
			ctx,
			{
				name = "folderPath",
				value = state.pathDraft,
				placeholder = "Folder path",
				oninput = handlers.input,
				onsubmit = handlers.submit,
				width = fieldWidth
			}
		),
		ui.iconButton(ctx, { name = "chevronUp", size = upSize, onClick = UP })
	})

	local scroll = app.services.scroll:offset("folders")
	local list = div():style(styles.list):scroll(scroll):onScroll(scrollHandler(app))
	if #state.entries == 0 then
		list:children({
			div():style(styles.empty):children(text(state.error or "No folders here"):style(state.error ~= nil and styles.emptyError or styles.emptyText))
		})
	else
		for _, entry in ipairs(state.entries) do
			list:children({
				ui.listRow(
					ctx,
					{
						height = rowHeight,
						padding = theme:px(8),
						gap = theme:px(8),
						justify = "space-between",
						onClick = entry.open,
						children = {
							div():style(styles.group):children({
								ui.icon(ctx, { name = "folder", size = theme:px(20), colour = theme:color("muted") }),
								text(entry.name):style(styles.name)
							}),
							ui.icon(ctx, { name = "chevronRight", size = theme:px(16), colour = theme:color("faint") })
						}
					}
				)
			})
		end
	end

	local primary = ui.button(
		ctx,
		{ label = "Use this folder", onClick = state.select, variant = "primary", width = primaryWidth, height = theme:px(36) }
	)
	local choose = ui.button(ctx, { label = "Choose folder…", onClick = CHOOSE, variant = "quiet", width = chooseWidth, height = theme:px(32) })
	local backButton = back ~= nil and ui.button(ctx, { label = "Back", onClick = back, width = backWidth, height = theme:px(36) }) or nil

	local footer
	if mobile then
		local row = div():style(styles.actions)
		if backButton ~= nil then row:children({ backButton }) end
		row:children({ choose })
		footer = div():style(styles.footerColumn):children({ primary, row })
	else
		local actions = div():style(styles.actions)
		if backButton ~= nil then actions:children({ backButton }) end
		actions:children({ primary })
		footer = div():style(styles.footer):children({ choose, actions })
	end

	local content = div():style(styles.section):children({
		div():style(styles.header):children({
			text("Choose your music folder"):style(styles.title),
			text("Everything under it is scanned locally."):style(styles.copy)
		}),
		pathRow,
		list
	})
	content:children({ footer })
	return content, sectionHeight
end

return folders
