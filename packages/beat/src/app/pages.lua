-- What the app draws. Pages are functions of state and window; they return elements and actions,
-- never mutate the app themselves.
local wonderland = require("wonderland")
local utf8 = require("wonderland.font.utf8")
local wonderlandElement = require("wonderland.element")
local path = require("path")
local ui = require("beat-ui")
local core = require("beat-core")
local render = require("beat.app.ui")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty
local util = core.util

local GITHUB = "https://github.com/bycruz/beat"

local pages = {}

--- How wide a string is, in the units this app sizes a text box from. A Lua length is bytes, not
--- characters: an emoji is four of them and a flag or a family is several codepoints that draw as
--- one picture. Counting codepoints, then giving wide scripts and emoji a full em while Latin
--- glyphs get an average advance, is enough to keep a label's box against its ink without asking
--- the font manager during a page build.
---@param value string
---@param size number # The font size it will be drawn at
---@param latin number # What an average Latin glyph is worth, as a fraction of an em
---@return number
local function textWidth(value, size, latin)
	local width, at = 0, 1
	local joined = false
	local previous = 0

	while at <= #value do
		local codepoint, nextAt = utf8.decode(value, at)
		at = nextAt

		if codepoint == 0x200D then
			joined = true
		elseif (codepoint >= 0x0300 and codepoint <= 0x036F)
		or (codepoint >= 0xFE00 and codepoint <= 0xFE0F)
		or (codepoint >= 0x1F3FB and codepoint <= 0x1F3FF) then
			-- A mark, a variation selector or a skin tone change is part of the picture before it.
		elseif (codepoint >= 0x1F000 and codepoint <= 0x1FAFF)
		or (codepoint >= 0x2600 and codepoint <= 0x27BF) then
			if joined or (codepoint >= 0x1F1E6 and codepoint <= 0x1F1FF
			and previous >= 0x1F1E6 and previous <= 0x1F1FF) then
				-- A joined emoji or the second half of a flag is the same picture.
			else
				width = width + size
			end
			joined = false
		elseif (codepoint >= 0x1100 and codepoint <= 0x115F)
		or (codepoint >= 0x2E80 and codepoint <= 0xA4CF)
		or (codepoint >= 0xAC00 and codepoint <= 0xD7A3)
		or (codepoint >= 0xF900 and codepoint <= 0xFAFF)
		or (codepoint >= 0xFE30 and codepoint <= 0xFE4F)
		or (codepoint >= 0xFF00 and codepoint <= 0xFF60)
		or (codepoint >= 0xFFE0 and codepoint <= 0xFFE6) then
			width = width + size
			joined = false
		else
			width = width + size * latin
			joined = false
		end
		previous = codepoint
	end

	return math.max(1, math.floor(width + 0.5))
end

--- The width Wonderland measures for a line, through the same text plugin that will draw it. A
--- style's automatic width means "fill the room I am given", not "shrink to this text", so the app
--- asks for the measured run and puts that width on the box. The codepoint estimate below is only a
--- fallback for a page built before a window's font manager exists.
---@param app beat.App
---@param value string
---@param style wonderland.StyleBuilder
---@return number?
local function measuredWidth(app, value, style)
	local layout = app.layoutPlugin
	if layout == nil or layout.textPlugin == nil then return nil end
	local line = wonderland.text(value):style(style)
	local ok = pcall(layout.textPlugin.measure, layout.textPlugin, line)
	if not ok or line.run == 0 then return nil end
	local run = wonderlandElement.runs[line.run]
	return run and run.width or nil
end

-- The sidebar needs the same art and tracks the playlists page does, but it is built before those
-- helpers are defined below.
local playlistTracks, playlistArt

--- The phone breakpoint. The 960×640 desktop still uses the icon rail; a phone gets the bottom
--- navigation and a full-width page.
---@param app beat.App
---@param width number
---@return boolean
function pages.mobile(app, width)
	return width < app.theme:px(760)
end

---@param app beat.App
---@param width number?
---@return number
function pages.pad(app, width)
	if width ~= nil and pages.mobile(app, width) then return app.theme:space(16) end
	return app.theme:space(32)
end

---@param app beat.App
---@param width number
---@return number
function pages.sidebarWidth(app, width)
	if pages.mobile(app, width) then return 0 end
	if app.settings.sidebarCollapsed or width < 1040 then return app.theme:px(76) end
	return app.theme:px(app.settings.sidebarWidth)
end

--- The room a page has inside the body: the shell, both paddings, and the scroll bar's strip.
---@param app beat.App
---@param width number
---@return number
function pages.contentWidth(app, width)
	return width - pages.sidebarWidth(app, width) - pages.pad(app, width) * 2 - app.theme:px(8)
end

---@param app beat.App
---@param width number
---@return number
function pages.topbarHeight(app, width)
	return app.theme:px(pages.mobile(app, width) and 56 or 64)
end

---@param app beat.App
---@param width number
---@return number
function pages.bottomHeight(app, width)
	local theme = app.theme
	if pages.mobile(app, width) then
		local player = app:currentTrack() ~= nil and theme:px(64) or 0
		return player + theme:px(58)
	end
	return app:currentTrack() ~= nil and theme:px(88) or 0
end

---@param app beat.App
---@param width number
---@param height number
---@return number
function pages.viewportHeight(app, width, height)
	return height - pages.topbarHeight(app, width) - pages.bottomHeight(app, width)
end

--- The same 1–5 column ladder for every album shelf. It is driven by the content box, because
--- the sidebar and the mobile bottom bars are not part of the width a grid can use.
---@param content number
---@return number
function pages.gridColumns(content)
	if content >= 900 then return 5 end
	if content >= 640 then return 4 end
	if content >= 420 then return 3 end
	if content >= 260 then return 2 end
	return 1
end

--- A floating panel that a phone can still hold: never wider than the window less its gutter.
---@param app beat.App
---@param window wonderland.RenderWindow
---@param max number
---@return number
function pages.panelWidth(app, window, max)
	local gutter = app.theme:space(pages.mobile(app, window.width) and 16 or 24)
	return math.min(app.theme:px(max), window.width - gutter * 2)
end

--- A named text field for a dialog. The text is a child of the input element rather than a
--- sibling drawn over it: the caret and a selection are placed from the run inside the field, so
--- text outside it leaves them at the field's origin with the wrong line height.
---@param app beat.App
---@param name string
---@param value string
---@param placeholder string
---@param oninput fun(value: string): any
---@param onsubmit fun(): any
---@param width number?
---@return wonderland.Element
local function dialogField(app, name, value, placeholder, oninput, onsubmit, width)
	local theme = app.theme
	local focused = app.layoutPlugin ~= nil and app.window ~= nil
	and app.layoutPlugin:getFocusedId(app.window) == name
	local shown = value ~= "" and value or (focused and " " or placeholder)
	local colour = value ~= "" and theme:color("text")
	or (focused and theme:color("text") or theme:color("faint"))
	local fieldStyle = sty():h(theme:px(34)):row():align("center")
	:pad(0, theme:px(10), 0, theme:px(10)):radius(theme:radius("sm")):bg(theme:color("surface"))
	:text(theme:type("sm")):fg(theme:color("text"))
	if width ~= nil then fieldStyle:w(width) else fieldStyle:wrel(1.0) end
	local field = div():style(fieldStyle)
	:input({
	name = name,
	value = value,
	oninput = oninput,
	onsubmit = onsubmit,
	})
	field:children(text(shown):style(theme:s():wrel(1.0):text(theme:type("sm")):fg(colour):ellipsis()))
	return field
end

--- Lay out tag pills in fixed columns. `action` is a function from a tag to the message its pill
--- sends, or nil for a read-only pill.
---@param app beat.App
---@param tags beat.Tag[]
---@param selected table<number, boolean>?
---@param action (fun(tag: beat.Tag): any)?
---@param width number
---@param columns number
---@param limit number?
---@return wonderland.Element?
local function tagPills(app, tags, selected, action, width, columns, limit)
	if #tags == 0 then return nil end
	local theme = app.theme
	local gap = theme:px(8)
	local pillWidth = math.max(theme:px(80), math.floor((width - gap * (columns - 1)) / columns))
	local rows = {}
	local row = {}
	local shown = 0

	for _, tag in ipairs(tags) do
			if limit ~= nil and shown >= limit then break end
			local active = selected ~= nil and selected[tag.id] == true
			local fg = active and theme.accentInk or theme:color("text")
			local pill = div()
			:style(sty():w(pillWidth):h(theme:px(28)):pad(0, theme:px(10), 0, theme:px(10))
			:radius(theme:radius("full")):align("center"):justify("center")
			:bg(active and theme:color("accent") or theme:color("elevated"))
			:border(theme:px(1), active and theme:color("accent") or theme:color("border")))
			:children(text(tag.name):style(theme:s():w(pillWidth - theme:px(20)):text(theme:type("xs"))
			:weight("semibold"):fg(fg):ellipsis()))
			if action ~= nil then pill:onClick(action(tag)) end
			row[#row + 1] = pill
			shown = shown + 1
			if #row == columns then
				rows[#rows + 1] = div():style(sty():row():h(theme:px(28)):gap(gap)):children(row)
				row = {}
			end
		end

	if #row > 0 then rows[#rows + 1] = div():style(sty():row():h(theme:px(28)):gap(gap)):children(row) end
	if limit ~= nil and #tags > limit then
		rows[#rows + 1] = text("+" .. tostring(#tags - limit) .. " more tags"):style(
		theme:s():text(theme:type("xs")):fg(theme:color("faint"))
		)
	end
	if #rows == 0 then return nil end
	local height = #rows * theme:px(28) + math.max(0, #rows - 1) * theme:px(8)
	if limit ~= nil and #tags > limit then height = height + theme:px(18) end
	return div():style(sty():column():wrel(1.0):h(height):gap(theme:px(8))):children(rows)
end

-- ────────────────────────────────────────────────────────────────
-- chrome
-- ────────────────────────────────────────────────────────────────

---@param progress beat.ScanProgress
---@return number
local function scanFraction(progress)
	if progress.files <= 0 then return 0 end
	return math.max(0, math.min(1, progress.inspected / progress.files))
end

---@param app beat.App
---@param width number
---@param height number
---@return wonderland.Element
local function sidebar(app, width, height)
	local theme = app.theme
	local collapsed = app.settings.sidebarCollapsed or width < 1040
	local side = pages.sidebarWidth(app, width)
	local current = app.page

	local nav = {
	{ kind = "home", icon = "home", label = "Home"},
	{ kind = "library", icon = "library", label = "Library"},
	{ kind = "playlists", icon = "playlists", label = "Playlists"},
	}

	local navRowHeight = theme:px(collapsed and 44 or 42)
	local navHeight = navRowHeight * #nav + math.max(0, #nav - 1) * theme:px(2) + theme:px(20)
	local navChildren = {}
	for _, item in ipairs(nav) do
			local active = current.kind == item.kind
			local fg = active and theme:color("text") or theme:color("muted")
			local bg = active and theme:color("elevated") or theme:color("sidebar", 0)
			local rowStyle = sty():row():wrel(1.0):h(navRowHeight):pad(0, theme:px(10), 0, theme:px(10))
			:gap(theme:px(12)):radius(theme:radius("sm")):align("center"):bg(bg)
			local rowHover = sty():row():wrel(1.0):h(navRowHeight):pad(0, theme:px(10), 0, theme:px(10))
			:gap(theme:px(12)):radius(theme:radius("sm")):align("center"):bg(theme:color("hover"))
			if collapsed then
				rowStyle:justify("center")
				rowHover:justify("center")
			end
			local row = div():style(rowStyle):hover(rowHover)
			:onClick({ type = "navigate", page = { kind = item.kind}})

			row:children(ui.icons.element(item.icon, theme:px(19), active and theme:color("accent") or fg))
			if not collapsed then
				row:children(text(item.label):style(theme:s():text(theme:type("base")):weight("semibold"):fg(fg)))
			end

			navChildren[#navChildren + 1] = row
		end

	local brandChildren = { ui.icons.element("logo", theme:px(22), theme:color("accent"))}
	if not collapsed then
		brandChildren[#brandChildren + 1] = text("beat"):style(
		theme:s():text(theme:type("xl")):weight("bold"):fg(theme:color("text"))
		)
	end
	local brandStyle = sty():row():wrel(1.0):h(theme:px(52)):gap(theme:px(10)):align("center")
	if collapsed then brandStyle:justify("center") end

	local rowGap = theme:px(3)
	local sectionGap = theme:px(4)
	local playlists = app:recentPlaylists(3)
	---@cast playlists beat.Playlist[]
	local rowCount = #playlists + 1
	local headerHeight = collapsed and theme:px(0) or theme:px(24)
	-- The sidebar gaps and the header are style values, so the hover hit test can be the rows'
	-- own geometry without asking the layout that has not run yet.
	local sectionTop = theme:px(52) + theme:px(1) + theme:px(16) + theme:px(1)
	+navHeight + theme:px(4) * 5
	local sectionInset = collapsed and sectionGap or headerHeight + sectionGap
	local available = height - sectionTop - sectionInset
	local baseRowHeight = theme:px(collapsed and 44 or 52)
	local rowHeight = math.min(baseRowHeight,
	math.max(theme:px(36), math.floor((available - (rowCount - 1) * rowGap) / rowCount)))
	local artSize = math.min(theme:px(collapsed and 36 or 40), rowHeight - theme:px(8))
	local rowStep = rowHeight + rowGap
	local listTop = sectionTop + sectionInset
	local rows = {}

	for _, playlist in ipairs(playlists) do
			local tracks = playlistTracks(app, playlist)
			local active = current.kind == "playlist" and current.id == playlist.id
			local style = sty():row():wrel(1.0):h(rowHeight):gap(theme:px(10)):align("center")
			:justify("space-between"):radius(theme:radius("sm"))
			:bg(active and theme:color("elevated") or theme:color("sidebar", 0))
			local over = sty():row():wrel(1.0):h(rowHeight):gap(theme:px(10)):align("center")
			:justify("space-between"):radius(theme:radius("sm")):bg(theme:color("hover"))
			if collapsed then
				style:justify("center")
				over:justify("center")
			end

			local row = div():style(style):hover(over)
			:onClick({ type = "navigate", page = { kind = "playlist", id = playlist.id}})
			:children(playlistArt(app, tracks, artSize, nil, playlist.name))

			if not collapsed then
				row:children(text(util.count(#tracks, "track")):style(theme:s():text(theme:type("xs"))
				:fg(theme:color("faint"))))
			end

			-- A row that is not being pointed at says nothing; the tooltip is where a playlist gets
			-- its name back. The list's own hit test is what knows which row the pointer is over.
			rows[#rows + 1] = row
		end

	local createStyle = sty():row():wrel(1.0):h(rowHeight):gap(theme:px(10)):align("center")
	:radius(theme:radius("sm")):bg(theme:color("accent", 0.13))
	local createHover = sty():row():wrel(1.0):h(rowHeight):gap(theme:px(10)):align("center")
	:radius(theme:radius("sm")):bg(theme:color("accent", 0.22))
	if collapsed then
		createStyle:justify("center")
		createHover:justify("center")
	else
		createStyle:pad(0, theme:px(8), 0, theme:px(8))
		createHover:pad(0, theme:px(8), 0, theme:px(8))
	end

	local create = div():style(createStyle):hover(createHover)
	:onClick({ type = "openPlaylistDialog", smart = false})
	:children({
	div():style(sty():size(artSize, artSize):radius(theme:radius("sm")):bg(theme:color("accent", 0.18))
	:align("center"):justify("center")):children(ui.icons.element("add", theme:px(18),
	theme:color("accent"))),
	})
	if not collapsed then
		create:children(text("New playlist"):style(theme:s():text(theme:type("sm")):weight("semibold")
		:fg(theme:color("accent"))))
	end
	rows[#rows + 1] = create

	local listHeight = #rows * rowHeight + math.max(0, #rows - 1) * rowGap

	---@param relY number
	---@return { type: string, id: number?, y: number? }?
	local function hoverAt(relY)
		local offset = relY - listTop
		local hovered = nil
		if offset >= 0 then
			local index = math.floor(offset / rowStep) + 1
			local within = offset - (index - 1) * rowStep
			if index <= #playlists and within < rowHeight then
				local rowTop = listTop + (index - 1) * rowStep
				local artX = collapsed and side / 2 or (theme:px(16) + artSize / 2)
				hovered = {
				id = playlists[index].id,
				y = rowTop + rowHeight / 2,
				-- The arrow meets the artwork's top edge, not the taller hover row around it.
				top = rowTop + (rowHeight - artSize) / 2,
				x = artX,
				height = artSize,
				}
			end
		end

		-- A message is a frame: moving inside one row, or over anything that has no shortcut,
		-- asks for nothing when the tooltip is already in the state that movement means.
		local old = app.hoverPlaylist
		if hovered == nil then
			if old == nil then return nil end
			return { type = "hoverPlaylist", id = nil}
		end
		if old ~= nil and old.id == hovered.id and old.y == hovered.y
		and old.top == hovered.top and old.x == hovered.x then return nil end
		return {
		type = "hoverPlaylist", id = hovered.id, y = hovered.y,
		top = hovered.top, x = hovered.x, height = hovered.height,
		}
	end

	return div()
	:style(sty():w(side):hrel(1.0):column():pad(0, theme:px(16), 0, theme:px(16))
	:gap(theme:px(4)):bg(theme:color("sidebar")))
	:resize({
	edge = "right",
	min = theme:px(200),
	max = theme:px(360),
	grab = theme:px(5),
	onchange = function(size)
		return { type = "sidebarWidth", width = size / theme.scale}
	end,
	})
	:onMouseMove(function(_, relY) return hoverAt(relY --[[@as number]]) end)
	:children({
	div():style(brandStyle):onClick({ type = "toggleSidebar"}):children(brandChildren),
	div():style(sty():h(1):bg(theme:color("border"))),
	div():style(sty():column():h(navHeight):gap(theme:px(2))
	:pad(theme:px(10), 0, 0, 0)):children(navChildren),
	div():style(sty():h(1):bg(theme:color("border"))),
	div():style(sty():h(theme:px(16))),
	div():style(sty():column():h(theme:px(collapsed and 0 or 28) + listHeight)
	:gap(sectionGap)):children({
	(function()
		if collapsed then return div():style(sty():h(theme:px(0))) end
		return div():style(sty():row():wrel(1.0):h(theme:px(24)):align("center")
		:justify("space-between")):children({
		text("PLAYLISTS"):style(theme:s():text(theme:type("xs"))
		:weight("bold"):fg(theme:color("faint"))),
		})
	end)(),
	div():style(sty():column():h(listHeight):gap(rowGap)):children(rows),
	}),
	})
end

--- The name a sidebar playlist hides until it is pointed at. It is drawn over the page rather
--- than inside the narrow sidebar, and clamped so the last row's label stays on screen.
---@param app beat.App
---@param width number
---@param height number
---@return wonderland.Element?
function pages.playlistTooltip(app, width, height)
	local hover = app.hoverPlaylist
	if hover == nil or app.taxonomy == nil then return nil end
	local playlist = app.taxonomy:playlist(hover.id)
	if playlist == nil then return nil end

	local theme = app.theme
	local pad = theme:px(8)
	local nameStyle = theme:s():text(theme:type("sm")):weight("semibold")
	local measured = measuredWidth(app, playlist.name, nameStyle)
	local fallback = textWidth(playlist.name, theme:type("sm"), 0.45)
	local border = theme:px(1)
	local nameWidth = math.min(theme:px(180), math.max(theme:px(8),
	math.ceil(measured or fallback)))
	local boxWidth = nameWidth + pad * 2 + border * 2
	local boxHeight = theme:px(30)
	local arrowWidth = theme:px(14)
	local arrowHeight = theme:px(7)
	local totalHeight = boxHeight + arrowHeight
	local artWidth = hover.height or theme:px(40)
	local centre = hover.x or (pages.sidebarWidth(app, width) / 2)
	local wrapperX = centre - artWidth / 2
	local rowTop = hover.top or (hover.y - (hover.height or theme:px(52)) / 2)
	local wrapperY = math.max(theme:px(8), rowTop - totalHeight)

	-- The box is as wide as the run Wonderland measured, so emoji and other wide glyphs keep
	-- their own padding rather than being sized by a byte count.
	local box = div()
	:style(sty():w(boxWidth):h(boxHeight):row():align("center")
	:pad(0, pad, 0, pad):radius(theme:radius("sm"))
	:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(4), theme:px(14), "#00000099"))
	:children({
	text(playlist.name):style(theme:s():w(nameWidth):text(theme:type("sm")):weight("semibold")
	:fg(theme:color("text"))),
	})

	local arrow = div():style(sty():w(arrowWidth):h(arrowHeight))
	:canvas(function(canvas)
		canvas:polygon({ 0, 0, canvas.width, 0, canvas.width / 2, canvas.height},
		theme:color("elevated"))
	end)

	return div()
	:style(sty():w(artWidth):h(totalHeight):offset(wrapperX, wrapperY):z(80):column():align("center"))
	:onMouseMove(function() return nil end)
	:children({ box, arrow})
end

--- The compact scan card: a floating island while the worker is reading, with the same progress
--- the sidebar footer keeps after it is collapsed. It only appears once there is a track to browse.
---@param app beat.App
---@param width number
---@return wonderland.Element?
function pages.scanIsland(app, width)
	if app.scan == nil or not app.scanIslandOpen or app.library == nil or #app.library.tracks == 0 then
		return nil
	end

	local theme = app.theme
	local progress = app.scan:progress()
	local fraction = scanFraction(progress)
	local islandWidth = math.min(theme:px(340), width - pages.pad(app, width) * 2)
	local islandHeight = theme:px(112)
	local pad = theme:px(14)
	local barHeight = theme:px(4)
	local radius = theme:radius("md")
	local margin = pages.mobile(app, width) and pages.pad(app, width) or theme:space(24)
	local current = nil
	if type(progress.current) == "string" then current = path.basename(progress.current) end
	local label = progress.phase == "enumerate" and "Finding music" or "Reading metadata"

	return div()
	:style(sty():w(islandWidth):h(islandHeight):offset(width - islandWidth - margin,
	pages.topbarHeight(app, width) + theme:space(8))
	:z(60):column():pad(pad, pad, 0, pad):gap(theme:px(8))
	:radius(radius):bg(theme:color("elevated"))
	:shadow(0, theme:px(12), theme:px(32), "#00000070"))
	:canvas(function(canvas)
		render.bottomBar(canvas, {
		x = -pad,
		y = islandHeight - pad - barHeight,
		width = islandWidth,
		height = barHeight,
		radius = radius,
		fraction = fraction,
		trackColour = theme:color("text", 0.1),
		fillColour = theme:color("accent"),
		})
	end)
	:children({
	div():style(sty():row():wrel(1.0):h(theme:px(22)):align("center"):justify("space-between")):children({
	div():style(sty():row():h(theme:px(22)):gap(theme:px(8)):align("center")):children({
	render.equalizer(app, true),
	text("Scanning music"):style(theme:s():text(theme:type("sm")):weight("semibold")
	:fg(theme:color("text"))),
	}),
	render.iconButton(app, "chevronUp", theme:px(22), { type = "hideScanIsland"}),
	}),
	div():style(sty():row():wrel(1.0):h(theme:px(16)):align("center")
	:justify("space-between")):children({
	text(label .. " · " .. progress.inspected .. " / " .. progress.files):style(
	theme:s():text(theme:type("xs")):fg(theme:color("muted"))
	),
	render.button(app, "Cancel", { type = "cancelScan"},
	{ height = theme:px(26), width = theme:px(66)}),
	}),
	current ~= nil and text(tostring(current)):style(theme:s():wrel(1.0):text(theme:type("xs"))
	:fg(theme:color("faint")):ellipsis()) or text(""):style(sty():h(theme:px(0))),
	})
end

--- The card that replaces the scanning island once the scan is done: same place, size and
--- surface, with a check and what the scan added. It is dismissed by a click or after five seconds.
---@param app beat.App
---@param width number
---@return wonderland.Element?
function pages.scanSummary(app, width)
	local summary = app.scanSummary
	if summary == nil then return nil end

	local theme = app.theme
	local islandWidth = math.min(theme:px(340), width - pages.pad(app, width) * 2)
	local islandHeight = theme:px(112)
	local pad = theme:px(14)
	local barHeight = theme:px(4)
	local radius = theme:radius("md")
	local margin = pages.mobile(app, width) and pages.pad(app, width) or theme:space(24)

	local detail = summary.skipped > 0
	and util.count(summary.skipped, "file") .. " skipped"
	or "Saved to your library"
	local detailColour = summary.skipped > 0 and theme:color("danger") or theme:color("muted")

	return div()
	:style(sty():w(islandWidth):h(islandHeight):offset(width - islandWidth - margin,
	pages.topbarHeight(app, width) + theme:space(8))
	:z(60):column():pad(pad, pad, 0, pad):gap(theme:px(8))
	:radius(radius):bg(theme:color("elevated"))
	:shadow(0, theme:px(12), theme:px(32), "#00000070"))
	:onClick({ type = "dismissScanSummary"})
	:canvas(function(canvas)
		render.bottomBar(canvas, {
		x = -pad,
		y = islandHeight - pad - barHeight,
		width = islandWidth,
		height = barHeight,
		radius = radius,
		fraction = 1,
		trackColour = theme:color("text", 0.1),
		fillColour = theme:color("accent"),
		})
	end)
	:children({
	div():style(sty():row():h(theme:px(22)):gap(theme:px(8)):align("center")):children({
	ui.icons.element("check", theme:px(18), theme:color("accent")),
	text("Scan complete"):style(theme:s():text(theme:type("sm")):weight("semibold")
	:fg(theme:color("text"))),
	}),
	text(util.count(summary.tracks, "track") .. " · " .. util.count(summary.albums, "album")):style(
	theme:s():text(theme:type("base")):weight("semibold"):fg(theme:color("text"))
	),
	text(detail):style(theme:s():text(theme:type("xs")):fg(detailColour)),
	})
end

---@param app beat.App
---@param width number
---@return wonderland.Element
local function topbar(app, width)
	local theme = app.theme
	local mobile = pages.mobile(app, width)
	local focused = app.layoutPlugin ~= nil and app.window ~= nil
	and app.layoutPlugin:getFocusedId(app.window) == "search"
	local search = app.search
	local available = pages.contentWidth(app, width)
	local leftWidth = available - theme:px(mobile and 48 or 44)
	local searchWidth = leftWidth - theme:px(mobile and 50 or 84)
	local pillHeight = theme:px(mobile and 38 or 34)
	local iconSize = theme:px(mobile and 40 or 32)

	local searchAreaWidth = searchWidth - theme:px(24) - theme:px(16) - theme:px(8)
	-(search ~= "" and theme:px(28) or 0)
	local searchArea = div():style(sty():w(searchAreaWidth):h(theme:px(32)):row():align("center"))
	local searchText = search ~= "" and search
	or (focused and " " or (width < 480 and "Search" or "Search artists, albums, tracks"))
	local searchColour = search ~= "" and theme:color("text")
	or (focused and theme:color("text") or theme:color("faint"))
	local searchInput = div()
	:style(sty():wrel(1.0):h(theme:px(32)):row():align("center")
	:pad(theme:px(10), 0, theme:px(10), 0):text(theme:type("sm")):fg(theme:color("text")))
	:input({
	name = "search",
	value = search,
	oninput = function(value) return { type = "search", value = value} end,
	})
	searchInput:children(text(searchText):style(theme:s():wrel(1.0):text(theme:type("sm"))
	:fg(searchColour):ellipsis()))

	searchArea:children({ searchInput})

	local field = div()
	:style(sty():row():wrel(1.0):h(theme:px(32)):gap(theme:px(8)):align("center"))
	:children({
	ui.icons.element("search", theme:px(16), theme:color("faint")),
	searchArea,
	})

	if search ~= "" then
		local closeColour = theme:color("muted")
		local closeWeight = math.max(1, theme:px(1.25))
		field:children(div():style(sty():size(theme:px(20), theme:px(20))
		:radius(theme:radius("full")):align("center"):justify("center"))
		:onClick({ type = "search", value = ""})
		:canvas(function(canvas)
			local middleX, middleY = canvas.width / 2, canvas.height / 2
			local arm = math.max(3, theme:px(4))
			canvas:line(middleX - arm, middleY - arm, middleX + arm, middleY + arm,
			closeWeight, closeColour)
			canvas:line(middleX + arm, middleY - arm, middleX - arm, middleY + arm,
			closeWeight, closeColour)
		end))
	end

	local function navButton(name, action, enabled)
		return render.iconButton(app, name, iconSize, enabled and action or nil, enabled)
	end

	local searchStyle = sty():row():w(searchWidth):h(pillHeight):radius(theme:radius("full"))
	:bg(focused and theme:color("hover") or theme:color("elevated"))
	:pad(0, theme:px(12), 0, theme:px(12)):align("center")

	local searchPill = div():style(searchStyle):children(field)
	if focused then
		-- A focus ring is painted over the pill rather than styled onto it: a border that takes
		-- part in layout shrinks the content box by a pixel and makes the field jump when focus
		-- arrives. The ring is outside the flow and the field keeps its exact position.
		searchPill:children(div():style(sty():w(searchWidth):h(pillHeight)
		:radius(theme:radius("full")):border(theme:px(1), theme:color("accent"))
		:offset(-theme:px(12), 0)))
	end

	local leftChildren = {
	navButton("chevronLeft", { type = "back"}, #app.history > 0),
	}
	if not mobile then
		leftChildren[#leftChildren + 1] = navButton("chevronRight", { type = "forward"}, #app.future > 0)
	end
	leftChildren[#leftChildren + 1] = searchPill
	local left = div():style(sty():row():w(leftWidth):h(pillHeight):gap(theme:px(10))
	:align("center")):children(leftChildren)

	return div()
	:style(sty():row():wrel(1.0):h(pages.topbarHeight(app, width))
	:pad(0, pages.pad(app, width), 0, pages.pad(app, width))
	:gap(theme:px(10)):align("center"):justify("space-between"))
	:children({
	left,
	render.iconButton(app, "settings", iconSize, { type = "navigate", page = { kind = "settings"}}),
	})
end

---@param app beat.App
---@param width number
---@return wonderland.Element
local function nowPlaying(app, width)
	local theme = app.theme
	local track = app:currentTrack()
	local player = app.player
	local height = theme:px(88)
	if track == nil then return div():style(sty():h(0)) end

	local album = app.library and app.library:album(track.albumId)
	if album == nil then
		album = {
		id = 0,
		title = track.album,
		artist = track.artist,
		tracks = {},
		coverPath = track.coverPath,
		coverTrack = track,
		}
	end
	---@cast track beat.Track
	---@cast album beat.Album
	local cover = render.cover(app, album, theme:px(56), theme:radius("sm"))
	if album.id ~= 0 then
		cover:onClick({ type = "navigate", page = { kind = "album", id = album.id}})
		cover:onContextMenu(function(_, _, _, _, _, windowX, windowY)
			return { type = "albumMenu", id = album.id, x = windowX, y = windowY}
		end)
	end

	local isPlaying = player:isPlaying()
	local controls = div():style(sty():row():align("center"):justify("center"):gap(theme:px(10))):children({
	render.iconButton(app, "shuffle", theme:px(28), { type = "shuffle"}, player.queue
	and player.queue.shuffle),
	render.iconButton(app, "previous", theme:px(28), { type = "previous"}),
	div():style(sty():size(theme:px(38), theme:px(38)):radius(theme:radius("full")):bg(theme:color("accent"))
	:align("center"):justify("center")):onClick({ type = "togglePlay"})
	:children(ui.icons.element(isPlaying and "pause" or "play", theme:px(20), theme.accentInk)),
	render.iconButton(app, "next", theme:px(28), { type = "next"}),
	render.iconButton(app, player.queue and player.queue.repeatMode == "one" and "repeatOne" or "repeat",
	theme:px(28), { type = "repeat"}, player.queue and player.queue.repeatMode ~= "off"),
	})

	local cards = div():style(sty():row():w(width > 1180 and theme:px(300) or theme:px(220)):h("auto")
	:align("center"):justify("center")):children(controls)
	local progressWidth = width > 1180 and theme:px(240) or theme:px(160)

	local sideWidth = math.max(theme:px(280), progressWidth + theme:px(44))
	local left = div():style(sty():row():w(sideWidth):h("auto"):gap(theme:px(14)):align("center"))
	:children({
	cover,
	div():style(sty():w(210):h("auto"):column():justify("center"):gap(2))
	:onClick(album.id ~= 0 and { type = "navigate", page = { kind = "album", id = album.id}} or nil)
	:children({
	text(track.title):style(theme:s():w(210):text(theme:type("base")):weight("semibold")
	:fg(theme:color("text")):ellipsis()),
	text(track.artist):style(theme:s():w(210):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()),
	}),
	})
	local right = div():style(sty():row():w(sideWidth):h("auto"):gap(theme:px(14)):align("center")
	:justify("end")):children({
	div():style(sty():column():w(progressWidth):h("auto"):justify("center"):align("end")
	:gap(theme:px(6))):children({
	render.progress(app, track, player, progressWidth),
	render.volume(app, progressWidth, progressWidth - theme:px(34) * 2 - theme:px(8) * 2),
	}),
	render.iconButton(app, app.expanded and "chevronDown" or "chevronUp", theme:px(30),
	{ type = "expandNowPlaying", open = not app.expanded}),
	})

	return div()
	:style(sty():row():wrel(1.0):h(height):bg(theme:color("surface")))
	:onMouseMove(function()
		if app.hoverPlaylist ~= nil then return { type = "hoverPlaylist", id = nil} end
		return nil
	end)
	:canvas(function(canvas) render.spectrumBackground(app, canvas) end)
	:children({
	div():style(sty():row():wrel(1.0):hrel(1.0):pad(0, theme:px(16), 0, theme:px(16))
	:gap(theme:px(14)):align("center"):justify("space-between")):children({ left, cards, right}),
	})
end

--- The phone mini player: one row above the bottom tabs. The whole row opens the individual
--- track view; the play and next controls inside it keep their own actions.
---@param app beat.App
---@param width number
---@return wonderland.Element
local function mobileNowPlaying(app, width)
	local theme = app.theme
	local track = app:currentTrack()
	local height = theme:px(64)
	if track == nil then return div():style(sty():h(0)) end

	local album = app.library and app.library:album(track.albumId)
	if album == nil then
		album = {
		id = 0,
		title = track.album,
		artist = track.artist,
		tracks = {},
		coverPath = track.coverPath,
		coverTrack = track,
		}
	end
	---@cast track beat.Track
	---@cast album beat.Album

	local pad = theme:space(12)
	local art = theme:px(42)
	local playSize = theme:px(40)
	local nextSize = theme:px(32)
	local gap = theme:space(10)
	local textWidth = width - pad * 2 - art - playSize - nextSize - gap * 3
	local playing = app.player:isPlaying()
	local duration = track.duration > 0 and track.duration or app.player:duration()
	local position = app.player:position()
	local fraction = duration > 0 and math.max(0, math.min(1, position / duration)) or 0

	return div()
	:style(sty():row():wrel(1.0):h(height):pad(0, pad, 0, pad):gap(gap)
	:align("center"):bg(theme:color("surface")))
	:onClick({ type = "expandNowPlaying", open = true})
	:canvas(function(canvas)
		local line = math.max(2, theme:px(2))
		canvas:rect(0, canvas.height - line, canvas.width, line, theme:color("text", 0.1))
		if fraction > 0 then
			canvas:rect(0, canvas.height - line, math.floor(canvas.width * fraction), line,
			theme:color("accent"))
		end
	end)
	:children({
	render.cover(app, album, art, theme:radius("sm")),
	div():style(sty():column():w(math.max(theme:px(70), textWidth)):hrel(1.0)
	:justify("center"):gap(1)):children({
	text(track.title):style(theme:s():w(math.max(theme:px(70), textWidth)):text(theme:type("sm"))
	:weight("semibold"):fg(theme:color("text")):ellipsis()),
	text(track.artist):style(theme:s():w(math.max(theme:px(70), textWidth)):text(theme:type("xs"))
	:fg(theme:color("muted")):ellipsis()),
	}),
	div():style(sty():size(playSize, playSize):radius(theme:radius("full")):bg(theme:color("accent"))
	:align("center"):justify("center")):onClick({ type = "togglePlay"})
	:children(ui.icons.element(playing and "pause" or "play", theme:px(19), theme.accentInk)),
	render.iconButton(app, "next", nextSize, { type = "next"}),
	})
end

--- The phone's bottom tabs. Search lives here as a destination as well as in the top bar, so a
--- thumb can reach every primary page without the desktop rail.
---@param app beat.App
---@param width number
---@return wonderland.Element
local function mobileNav(app, width)
	local theme = app.theme
	local height = theme:px(58)
	local items = {
	{ kind = "home", icon = "home", label = "Home"},
	{ kind = "library", icon = "library", label = "Library"},
	{ kind = "search", icon = "search", label = "Search"},
	{ kind = "playlists", icon = "playlists", label = "Playlists"},
	}
	local tabWidth = math.floor(width / #items)
	local tabs = {}
	for _, item in ipairs(items) do
			local active = app.page.kind == item.kind
			or (item.kind == "search" and app.page.kind == "searchAll")
			or (item.kind == "playlists" and app.page.kind == "playlist")
			local colour = active and theme:color("accent") or theme:color("muted")
			tabs[#tabs + 1] = div()
			:style(sty():w(tabWidth):hrel(1.0):column():align("center"):justify("center"):gap(2))
			:hover(sty():w(tabWidth):hrel(1.0):column():align("center"):justify("center"):gap(2)
			:bg(theme:color("hover")))
			:onClick({ type = "navigate", page = { kind = item.kind}})
			:children({
			ui.icons.element(item.icon, theme:px(21), colour),
			text(item.label):style(theme:s():text(theme:type("xs")):weight("semibold"):fg(colour)),
			})
		end

	return div()
	:style(sty():row():wrel(1.0):h(height):bg(theme:color("surface")))
	:children(tabs)
end

---@param app beat.App
---@param track beat.Track
---@param player beat.Player
---@param width number
---@return wonderland.Element
function render.progress(app, track, player, width)
	local theme = app.theme
	local duration = track.duration > 0 and track.duration or player:duration()
	local position = player:position()
	local clockWidth = theme:px(34)
	local gap = theme:px(8)
	local trackWidth = width - clockWidth * 2 - gap * 2

	local function clock(value)
		return div():style(sty():w(clockWidth):h(theme:px(18)):row():align("center"):justify("center"))
		:children(text(util.clock(value)):style(theme:s():text(theme:type("xs"))
		:fg(theme:color("faint"))))
	end

	return div():style(sty():w(width):h(theme:px(18)):row():align("center"):gap(gap)):children({
	clock(position),
	render.slider(app, {
	width = trackWidth,
	value = position,
	min = 0,
	max = duration > 0 and duration or 1,
	onchange = function(value) return { type = "seek", seconds = value} end,
	trackColour = theme:color("text", 0.12),
	fillColour = theme:color("text"),
	thumbColour = theme:color("text"),
	}),
	clock(duration),
	})
end

---@param app beat.App
---@param width number
---@param trackWidth number? # The slider track, when it should line up with another slider's track
---@return wonderland.Element
function render.volume(app, width, trackWidth)
	local theme = app.theme
	local volume = app.settings.isMuted and 0 or app.settings.volume
	local iconSlot = trackWidth ~= nil and theme:px(34) or theme:px(22)
	local sliderWidth = trackWidth or (width - theme:px(30))

	return div():style(sty():w(width):h(theme:px(22)):row():align("center"):gap(theme:px(8))):children({
	div():style(sty():w(iconSlot):h(theme:px(22)):row():align("center"):justify("center")):children(
	render.iconButton(app, app.settings.isMuted and "mute" or "volume", theme:px(22),
	{ type = "mute"})
	),
	render.slider(app, {
	width = sliderWidth,
	value = volume,
	min = 0,
	max = 1,
	onchange = function(value) return { type = "volume", value = value} end,
	trackColour = theme:color("text", 0.12),
	fillColour = theme:color("muted"),
	thumbColour = theme:color("text"),
	thumbSize = theme:px(12),
	}),
	})
end

-- ────────────────────────────────────────────────────────────────
-- pages
-- ────────────────────────────────────────────────────────────────

---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element
local function home(app, window)
	local theme = app.theme
	local library = app.library
	if library == nil or (app.scan ~= nil and #library.tracks == 0) then
		if app.scan ~= nil then
			local progress = app.scan:progress()
			local current = progress.current
			local currentName = nil
			if type(current) == "string" then currentName = path.basename(current) end
			local scanning = {
			render.equalizer(app, true),
			text(progress.phase == "enumerate" and "Finding your music" or "Reading your music"):style(
			theme:s():text(theme:type("xl")):weight("bold"):fg(theme:color("text"))
			),
			text(util.count(progress.tracks, "track") .. " · " .. progress.inspected .. " / "
			.. progress.files):style(theme:s():text(theme:type("sm")):fg(theme:color("muted"))),
			render.meter(theme:px(420), theme:px(4), scanFraction(progress),
			theme:color("text", 0.1), theme:color("accent")),
			}
			if currentName ~= nil then
				scanning[#scanning + 1] = text(tostring(currentName)):style(
				theme:s():w(theme:px(520)):text(theme:type("xs")):fg(theme:color("faint")):ellipsis()
				)
			end
			if progress.skipped > 0 then
				scanning[#scanning + 1] = text(util.count(progress.skipped, "file") .. " skipped"):style(
				theme:s():text(theme:type("xs")):fg(theme:color("danger"))
				)
			end
			scanning[#scanning + 1] = render.button(app, "Cancel scan", { type = "cancelScan"},
			{ height = theme:px(30), width = theme:px(110)})
			return div():style(sty():fill():column():align("center"):justify("center")
			:gap(theme:px(14))):children(scanning)
		end

		return render.empty(app, "Your library is empty", "Choose a folder and every track in it appears here.",
		"Choose a folder", { type = "chooseFolder"})
	end

	local content = pages.contentWidth(app, window.width)
	local columns = pages.gridColumns(content)
	local gap = theme:space(16)
	local cardWidth = math.max(120, math.floor((content - gap * (columns - 1)) / columns))
	local recent = library:recentlyAdded(columns)

	local cardHeight = render.albumCardHeight(app, cardWidth)
	local sectionHeight = theme:px(24)
	local gap = theme:space(16)

	local function cardRow(albums, limit)
		local children = {}
		for at, album in ipairs(albums) do
				if limit ~= nil and at > limit then break end
				children[#children + 1] = render.albumCard(app, album, cardWidth,
				{ type = "navigate", page = { kind = "album", id = album.id}},
				{ type = "playAlbum", id = album.id})
			end
		return div():style(sty():row():wrel(1.0):h(cardHeight):gap(gap)):children(children)
	end

	local listened = app.taxonomy:recentAlbums(library, columns)
	local children = {}
	local height = 0
	if #listened > 0 then
		children[#children + 1] = render.section(app, "Recently listened")
		children[#children + 1] = cardRow(listened)
		height = height + sectionHeight + cardHeight + gap * 2
	end
	children[#children + 1] = render.section(app, "Recently added")
	children[#children + 1] = cardRow(recent)
	children[#children + 1] = render.section(app, "Your albums")
	children[#children + 1] = cardRow(library.albums, columns)
	height = height + sectionHeight + cardHeight + sectionHeight + cardHeight + gap * 4

	if #library.artists > 0 then
		local artists = {}
		for at = 1, math.min(columns, #library.artists) do artists[#artists + 1] = library.artists[at] end
		local cards = {}
		for _, artist in ipairs(artists) do
				local album = artist.albums[1]
				cards[#cards + 1] = div()
				:style(sty():w(cardWidth):h(cardHeight):column():gap(theme:px(6)))
				:hover(sty():w(cardWidth):h(cardHeight):column():gap(theme:px(6)):bright(1.08))
				:onClick({ type = "navigate", page = { kind = "artist", id = artist.id}})
				:children({
				album ~= nil and render.cover(app, album, cardWidth, theme:radius("full"))
				or div():style(sty():size(cardWidth, cardWidth):radius(theme:radius("full"))
				:bg(theme:color("elevated"))),
				text(artist.name):style(theme:s():w(cardWidth):text(theme:type("base")):weight("semibold")
				:fg(theme:color("text")):ellipsis()),
				text("Artist"):style(theme:s():text(theme:type("sm")):fg(theme:color("muted"))),
				})
			end
		children[#children + 1] = render.section(app, "Artists")
		children[#children + 1] = div():style(sty():row():wrel(1.0):h(cardHeight):gap(gap)):children(cards)
		height = height + sectionHeight + cardHeight + gap * 2
	end

	return div():style(sty():column():wrel(1.0):h(height):gap(gap)):children(children)
end

---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element
local SORT_OPTIONS = {
{ key = "title", label = "Title"},
{ key = "artist", label = "Artist"},
{ key = "year", label = "Year"},
{ key = "recent", label = "Recently added"},
{ key = "modified", label = "File last modified"},
}

--- A hue and brightness grid: the twelve hues of a colour wheel at three tones each.
---@param hue number # From nought to one
---@param saturation number
---@param value number
---@return string
local function hsvColour(hue, saturation, value)
	local at = hue * 6
	local index = math.floor(at) % 6
	local fraction = at - math.floor(at)
	local p = value * (1 - saturation)
	local q = value * (1 - fraction * saturation)
	local t = value * (1 - (1 - fraction) * saturation)
	local r, g, b
	if index == 0 then r, g, b = value, t, p
	elseif index == 1 then r, g, b = q, value, p
	elseif index == 2 then r, g, b = p, value, t
	elseif index == 3 then r, g, b = p, q, value
	elseif index == 4 then r, g, b = t, p, value
	else r, g, b = value, p, q end
	return string.format("#%02x%02x%02x", math.floor(r * 255 + 0.5),
	math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

local ACCENT_GRID = {}
for tone = 1, 3 do
		for hue = 0, 11 do
				local saturation = tone == 1 and 0.45 or tone == 2 and 0.72 or 0.94
				local value = tone == 3 and 0.72 or 1
				ACCENT_GRID[#ACCENT_GRID + 1] = hsvColour(hue / 12, saturation, value)
			end
	end

local function libraryPage(app, window)
	local theme = app.theme
	local library = app.library
	if library == nil then
		return render.empty(app, "Awkward. Nothing's here.", nil, "Choose a folder",
		{ type = "chooseFolder"}, "😬")
	end
	local content = pages.contentWidth(app, window.width)
	local albums = app:albumList()
	local mobile = pages.mobile(app, window.width)

	local list = app.settings.view == "list"
	local columns
	if content >= 900 then
		columns = 5
	elseif content >= 640 then
		columns = 4
	elseif content >= 420 then
		columns = 3
	elseif content >= 260 then
		columns = 2
	else
		columns = 1
	end
	local gap = theme:space(16)
	local cardWidth = math.max(120, math.floor((content - gap * (columns - 1)) / columns))

	-- Below this the title and the controls cannot sit on one line without one covering the
	-- other, so the controls move under the title and the header grows by a row.
	local stacked = content < 480
	local headerHeight = stacked and theme:px(104) or theme:px(58)
	local viewWidth = content < 320 and theme:px(56) or theme:px(70)
	local sortWidth = math.max(theme:px(88),
	math.min(theme:px(150), content - viewWidth - theme:px(8)))
	local titleWidth = math.max(theme:px(0), content - sortWidth - viewWidth - theme:space(16))

	local titleBlock = div():style(sty():column():w(stacked and content or titleWidth)
	:h(stacked and theme:px(58) or headerHeight):gap(4)):children({
	text("Your library"):style(theme:s():wrel(1.0):text(theme:type("xxl")):weight("bold")
	:fg(theme:color("text")):ellipsis()),
	text(util.count(#albums, "album") .. " · " .. util.count(#library.tracks, "track")):style(
	theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()
	),
	})

	local controls = div():style(sty():row():h(theme:px(32)):gap(theme:px(8)):align("center")
	:justify(stacked and "start" or "end")):children({
	render.button(app, sortWidth < theme:px(130) and "Sort" or ("Sort: " .. app:sortLabel()),
	{ type = "sortMenu"},
	{ height = theme:px(32), width = sortWidth}),
	render.button(app, list and "Grid" or "List", { type = "toggleView"},
	{ height = theme:px(32), width = viewWidth}),
	})

	local header = div()
	:style(stacked
	and sty():column():wrel(1.0):h(headerHeight):gap(theme:px(10))
	or sty():row():wrel(1.0):h(headerHeight):align("center"):justify("space-between"))
	:children({
	titleBlock,
	controls,
	})

	if #albums == 0 then
		return render.empty(app, "Awkward. Nothing's here.", nil, "Choose a folder",
		{ type = "chooseFolder"}, "😬")
	end

	local cardHeight = render.albumCardHeight(app, cardWidth)
	local rowHeight = list and theme:px(64) or (cardHeight + theme:space(12))
	local totalRows = list and #albums or math.ceil(#albums / columns)
	local contentHeight = headerHeight + theme:space(18) + totalRows * rowHeight
	local viewport = pages.viewportHeight(app, window.width, window.height)
	app.scrollMax = math.max(0, contentHeight - viewport)
	local scroll = app:scrollOffset(app:pageKey())
	local listStart = headerHeight + theme:space(18)
	local first, last, top = app:slices(#albums, list and 1 or columns, rowHeight,
	math.max(0, scroll - listStart), viewport)
	---@cast first number
	---@cast last number
	---@cast top number
	local children = {}

	if top > 0 then children[#children + 1] = div():style(sty():h(top)) end

	if list then
		for at = first, last do
				local album = albums[at]
				children[#children + 1] = div()
				:style(sty():row():w(content):h(rowHeight):gap(theme:px(14)):align("center")
				:radius(theme:radius("sm")))
				:hover(sty():row():w(content):h(rowHeight):gap(theme:px(14)):align("center")
				:radius(theme:radius("sm")):bg(theme:color("hover")))
				:onClick({ type = "navigate", page = { kind = "album", id = album.id}})
				:onContextMenu(function(_, _, _, _, _, windowX, windowY)
					return { type = "albumMenu", id = album.id, x = windowX, y = windowY}
				end)
				:children({
				render.cover(app, album, theme:px(48), theme:radius("sm")),
				div():style(sty():column():w(content - theme:px(mobile and 80 or 190))):children({
				text(album.title):style(theme:s():wrel(1.0):text(theme:type("base"))
				:weight("semibold"):fg(theme:color("text")):ellipsis()),
				text(album.artist .. (album.year and (" · " .. album.year) or "")):style(
				theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()),
				}),
				(not mobile) and text(util.count(#album.tracks, "track")):style(
				theme:s():text(theme:type("sm")):fg(theme:color("muted"))) or div():style(
				sty():w(0):h(0)),
				(not mobile) and text(util.duration(album.duration)):style(
				theme:s():text(theme:type("sm")):fg(theme:color("faint"))) or div():style(
				sty():w(0):h(0)),
				})
			end
	else
		local row = {}
		for at = first, last do
				local album = albums[at]
				row[#row + 1] = render.albumCard(app, album, cardWidth,
				{ type = "navigate", page = { kind = "album", id = album.id}},
				{ type = "playAlbum", id = album.id})
				if #row == columns or at == last then
					children[#children + 1] = div():style(sty():row():wrel(1.0):h(rowHeight):gap(gap)):children(row)
					row = {}
				end
			end
	end

	local usedRows = last - first + 1
	local bottomPad = math.max(0, (totalRows - (first - 1) - usedRows) * rowHeight)
	if bottomPad > 0 then children[#children + 1] = div():style(sty():h(bottomPad)) end

	return div():style(sty():column():wrel(1.0):h(contentHeight):gap(theme:space(18))):children({
	header,
	div():style(sty():column():wrel(1.0):h(totalRows * rowHeight):gap(0)):children(children),
	})
end

--- One collection is a cover, a title block, and a track table. Albums and playlist pages
--- differ in the words and the one extra control they offer, not in how the page is built.
---@param app beat.App
---@param window wonderland.RenderWindow
---@param opts { label: string, icons: wonderland.Element?, cover: fun(size: number): wonderland.Element, coverMenu: fun(x: number, y: number, width: number, height: number, modifiers: any?, windowX: number, windowY: number): any?, title: string, subtitle: string, subtitleAction: any?, meta: string, playAction: any, playIcon: string, shuffleAction: any, addAction: any?, tracks: beat.Track[], trackAction: fun(track: beat.Track, at: number): any, trackIndex: (fun(track: beat.Track, at: number): number)?, empty: wonderland.Element?, titleOnly: boolean? }
---@return wonderland.Element
local function collectionPage(app, window, opts)
	local theme = app.theme
	local mobile = pages.mobile(app, window.width)
	local stacked = mobile and window.height >= theme:px(560)
	local content = pages.contentWidth(app, window.width)
	local coverSize
	if stacked then
		coverSize = math.min(theme:px(150), content)
	elseif mobile then
		coverSize = math.min(theme:px(120), math.floor(content * 0.25))
	else
		coverSize = math.min(theme:px(224), math.floor(content * 0.32))
	end
	local titleSize = theme:type(mobile and "xxl" or "hero")
	local labelHeight = theme:px(16)
	local titleHeight = math.floor(titleSize * 1.25)
	local subtitleHeight = math.floor(theme:type("md") * 1.3)
	local metaHeight = math.floor(theme:type("sm") * 1.3)
	local actionsHeight = theme:px(52)
	local infoHeight = labelHeight + titleHeight + subtitleHeight + metaHeight + actionsHeight
	+theme:px(8) * 4
	local heroHeight = stacked and (coverSize + theme:space(16) + infoHeight)
	or (coverSize + theme:space(mobile and 70 or 90))
	local hasTracks = #opts.tracks > 0
	local rowsHeight = hasTracks and #opts.tracks * theme:px(48)
	or (opts.empty ~= nil and theme:px(120) or 0)
	local trackListHeight = theme:space(20) + (hasTracks and theme:px(34) or 0)
	+rowsHeight + theme:space(24)
	local current = app:currentTrack()
	local playing = app.player:isPlaying()

	local cover = div():style(sty():size(coverSize, coverSize):radius(theme:radius("lg")))
	if opts.coverMenu ~= nil then cover:onContextMenu(opts.coverMenu) end
	cover:children({ opts.cover(coverSize)})

	local labelChildren = {
	text(opts.label):style(theme:s():text(theme:type("xs")):weight("bold"):fg(theme:color("muted"))),
	}
	if opts.icons ~= nil then labelChildren[#labelChildren + 1] = opts.icons end
	local subtitle = text(opts.subtitle):style(theme:s():wrel(1.0):text(theme:type("md"))
	:weight("semibold"):fg(theme:color("text")):ellipsis())
	if opts.subtitleAction ~= nil then subtitle:onClick(opts.subtitleAction) end

	local actions = {
	div():style(sty():size(theme:px(52), theme:px(52)):radius(theme:radius("full")):bg(theme:color("accent"))
	:align("center"):justify("center"))
	:onClick(opts.playAction)
	:children(ui.icons.element(opts.playIcon, theme:px(24), theme.accentInk)),
	render.iconButton(app, "shuffle", theme:px(30), opts.shuffleAction),
	}
	if opts.addAction ~= nil then
		actions[#actions + 1] = render.iconButton(app, "add", theme:px(30), opts.addAction)
	end

	local info = div():style(sty():column():h(stacked and infoHeight or heroHeight)
	:justify("center"):gap(theme:px(8)):wrel(1.0)):children({
	div():style(sty():row():h(theme:px(16)):gap(theme:px(7)):align("center")):children(labelChildren),
	text(opts.title):style(theme:s():text(titleSize):weight("bold")
	:fg(theme:color("text")):ellipsis()),
	subtitle,
	text(opts.meta):style(theme:s():wrel(1.0):text(theme:type("sm"))
	:fg(theme:color("muted")):ellipsis()),
	div():style(sty():row():h(theme:px(52)):gap(theme:px(10)):align("center")):children(actions),
	})
	local hero
	if stacked then
		hero = div():style(sty():column():wrel(1.0):h(heroHeight):gap(theme:space(16))):children({
		div():style(sty():row():wrel(1.0):h(coverSize):justify("center")):children({ cover}),
		info,
		})
	else
		hero = div():style(sty():row():wrel(1.0):h(heroHeight):pad(0, 0, 0, 0)
		:gap(theme:space(28)):align("center")):children({ cover, info})
	end

	local rows = {}
	if hasTracks then
		rows[#rows + 1] = div():style(sty():row():w(content):h(theme:px(34))
		:pad(0, theme:px(10), 0, theme:px(10)):gap(theme:px(12)):align("center")):children({
		text("#"):style(theme:s():w(24):text(theme:type("xs")):weight("bold")
		:fg(theme:color("faint"))),
		text("TITLE"):style(theme:s():w(content - theme:px(122)):text(theme:type("xs"))
		:weight("bold"):fg(theme:color("faint"))),
		text("TIME"):style(theme:s():w(54):text(theme:type("xs")):weight("bold")
		:fg(theme:color("faint"))),
		})
	end

	local trackStart = heroHeight + theme:space(20) + (hasTracks and theme:px(34) or 0)
	local viewport = pages.viewportHeight(app, window.width, window.height)
	app.scrollMax = math.max(0, heroHeight + trackListHeight + theme:space(20) - viewport)
	local scroll = app:scrollOffset(app:pageKey())
	local first, last, top = app:slices(#opts.tracks, 1, theme:px(48),
	math.max(0, scroll - trackStart), viewport)
	---@cast first number
	---@cast last number
	---@cast top number

	if top > 0 then rows[#rows + 1] = div():style(sty():h(top)) end
	for at = first, last do
			local track = opts.tracks[at]
			if track ~= nil then
				local number = opts.trackIndex ~= nil and opts.trackIndex(track, at) or at
				rows[#rows + 1] = render.trackRow(app, track, number,
				current ~= nil and current.id == track.id, playing,
				opts.trackAction(track, at), content, false, opts.titleOnly)
			end
		end
	if #opts.tracks == 0 and opts.empty ~= nil then rows[#rows + 1] = opts.empty end

	return div():style(sty():column():wrel(1.0):h(heroHeight + trackListHeight)):children({
	hero,
	div():style(sty():column():wrel(1.0):h(trackListHeight):pad(theme:space(20), 0, theme:space(24), 0))
	:children(rows),
	})
end

---@param app beat.App
---@param window wonderland.RenderWindow
---@param album beat.Album
---@return wonderland.Element
local function albumPage(app, window, album)
	local thisAlbum = app:currentTrack() ~= nil and app:currentTrack().albumId == album.id
	local playing = app.player:isPlaying()
	return collectionPage(app, window, {
	label = "ALBUM",
	cover = function(size) return render.cover(app, album, size, app.theme:radius("lg"), true) end,
	coverMenu = function(_, _, _, _, _, windowX, windowY)
		return { type = "albumMenu", id = album.id, x = windowX, y = windowY}
	end,
	title = album.title,
	subtitle = album.artist,
	subtitleAction = { type = "navigate", page = { kind = "artist", id = album.artistId}},
	meta = (album.year and (album.year .. " · ") or "") .. util.count(#album.tracks, "track")
	.. " · " .. util.duration(album.duration),
	playAction = thisAlbum and { type = "togglePlay"} or { type = "playAlbum", id = album.id},
	playIcon = playing and thisAlbum and "pause" or "play",
	titleOnly = true,
	shuffleAction = { type = "playAlbum", id = album.id, shuffle = true},
	tracks = album.tracks,
	trackAction = function(track)
		return { type = "playTrack", trackId = track.id, albumId = album.id}
	end,
	trackIndex = function(track, at) return track.number or at end,
	})
end

---@param app beat.App
---@param window wonderland.RenderWindow
---@param artist beat.Artist
---@return wonderland.Element
local function artistPage(app, window, artist)
	local theme = app.theme
	local content = pages.contentWidth(app, window.width)
	local heroSize = math.min(theme:px(160), math.floor(content * 0.24))
	local heroHeight = heroSize + theme:space(24)
	local album = artist.albums[1]
	local columns = pages.gridColumns(content)
	local gap = theme:space(16)
	local cardWidth = math.max(120, math.floor((content - gap * (columns - 1)) / columns))
	local cardHeight = render.albumCardHeight(app, cardWidth)
	local topCount = math.min(6, #artist.tracks)
	local topHeight = theme:px(24) + topCount * theme:px(48)
	local albumRows = math.ceil(#artist.albums / columns)
	local rowHeight = cardHeight + gap
	local albumsHeight = theme:px(24) + albumRows * rowHeight
	local albumStart = heroHeight + topHeight + theme:space(144)
	local contentHeight = albumStart + albumsHeight
	local viewport = pages.viewportHeight(app, window.width, window.height)
	app.scrollMax = math.max(0, contentHeight - viewport)
	local scroll = app:scrollOffset(app:pageKey())
	local first, last, sliceTop = app:slices(#artist.albums, columns, rowHeight,
	math.max(0, scroll - albumStart), viewport)
	---@cast first number
	---@cast last number
	---@cast sliceTop number

	local hero = div():style(sty():row():wrel(1.0):h(heroHeight):pad(0, 0, 0, 0):gap(theme:space(24))
	:align("center")):children({
	album ~= nil and render.cover(app, album, heroSize, theme:radius("lg"), true)
	or div():style(sty():size(heroSize, heroSize):radius(theme:radius("lg")):bg(theme:color("elevated"))),
	div():style(sty():column():h(heroHeight):justify("center"):gap(theme:px(8))):children({
	text("ARTIST"):style(theme:s():text(theme:type("xs")):weight("bold"):fg(theme:color("muted"))),
	text(artist.name):style(theme:s():text(theme:type("hero")):weight("bold")
	:fg(theme:color("text"))),
	text(util.count(#artist.albums, "album") .. " · " .. util.count(#artist.tracks, "track")):style(
	theme:s():text(theme:type("sm")):fg(theme:color("muted"))
	),
	div():style(sty():row():h(theme:px(38)):gap(theme:px(10)):align("center")):children({
	div():style(sty():size(theme:px(38), theme:px(38)):radius(theme:radius("full"))
	:bg(theme:color("accent")):align("center"):justify("center"))
	:onClick({ type = "playArtist", id = artist.id})
	:children(ui.icons.element("play", theme:px(18), theme.accentInk)),
	text("Play all"):style(theme:s():text(theme:type("sm")):weight("semibold")
	:fg(theme:color("text"))):onClick({ type = "playArtist", id = artist.id}),
	}),
	}),
	})

	local top = {}
	for index, track in ipairs(artist.tracks) do
			if index > 6 then break end
			top[#top + 1] = render.trackRow(app, track, index,
			app:currentTrack() ~= nil and app:currentTrack().id == track.id, app.player:isPlaying(),
			{ type = "playTrack", trackId = track.id, artistId = artist.id}, content, true)
		end

	local rows = {}
	if sliceTop > 0 then rows[#rows + 1] = div():style(sty():h(sliceTop)) end
	local row = {}
	for at = first, last do
			local release = artist.albums[at]
			if release ~= nil then
				row[#row + 1] = render.albumCard(app, release, cardWidth,
				{ type = "navigate", page = { kind = "album", id = release.id}},
				{ type = "playAlbum", id = release.id})
			end
			if #row == columns or at == last then
				rows[#rows + 1] = div():style(sty():row():wrel(1.0):h("auto"):gap(gap)):children(row)
				row = {}
			end
		end

	return div():style(sty():column():wrel(1.0):h(contentHeight):gap(theme:space(24))):children({
	hero,
	render.section(app, "Top tracks"),
	div():style(sty():column():wrel(1.0):h(topHeight):gap(2)):children(top),
	render.section(app, "Albums"),
	div():style(sty():column():wrel(1.0):h(albumsHeight):gap(gap)):children(rows),
	})
end

--- The tag filters under search. Selecting more than one narrows to tracks that have all of
--- them; the Playlists page has the same idea as a saved smart playlist.
---@param app beat.App
---@param width number
---@return wonderland.Element?
---@return number
local function searchTagFilter(app, width)
	local tags = app.taxonomy:visibleTags()
	if #tags == 0 then return nil, 0 end
	local theme = app.theme
	local columns = width >= 900 and 6 or (width >= 600 and 4 or 3)
	local pills = tagPills(app, tags, app.tagFilter, function(tag)
		return { type = "toggleTagFilter", id = tag.id}
	end, width, columns)
	if pills == nil then return nil, 0 end

	local headerActions = {}
	if next(app.tagFilter) ~= nil then
		headerActions[#headerActions + 1] = text("All"):style(theme:s():text(theme:type("xs"))
		:weight("semibold"):fg(app.tagFilterMatch == "all" and theme:color("accent")
		or theme:color("muted"))):onClick({ type = "tagFilterMatch", value = "all"})
		headerActions[#headerActions + 1] = text("Any"):style(theme:s():text(theme:type("xs"))
		:weight("semibold"):fg(app.tagFilterMatch == "any" and theme:color("accent")
		or theme:color("muted"))):onClick({ type = "tagFilterMatch", value = "any"})
		headerActions[#headerActions + 1] = text("Clear"):style(theme:s():text(theme:type("xs"))
		:weight("semibold"):fg(theme:color("accent"))):onClick({ type = "clearTagFilter"})
	end
	local headerChildren = {
	text("Filter by tag"):style(theme:s():wrel(1.0):text(theme:type("xs")):weight("bold")
	:fg(theme:color("muted"))),
	div():style(sty():row():w(theme:px(120)):gap(theme:px(8)):align("center")
	:justify("end")):children(headerActions),
	}

	local rows = math.ceil(#tags / columns)
	local height = theme:px(18) + theme:px(8) + rows * theme:px(28)
	+math.max(0, rows - 1) * theme:px(8) + theme:px(4)
	return div():style(sty():column():wrel(1.0):h(height):gap(theme:px(8))):children({
	div():style(sty():row():wrel(1.0):h(theme:px(18)):justify("space-between"):align("center")):children(
	headerChildren),
	pills,
	}), height
end

---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element
local function searchPage(app, window)
	local theme = app.theme
	local library = app.library
	if library == nil then
		return render.empty(app, "Search your library", "Choose a folder first.", "Choose a folder",
		{ type = "chooseFolder"})
	end

	local content = pages.contentWidth(app, window.width)
	local filter, filterHeight = searchTagFilter(app, content)
	local columns = pages.gridColumns(content)
	local gap = theme:space(16)
	local cardWidth = math.max(120, math.floor((content - gap * (columns - 1)) / columns))
	local cardHeight = render.albumCardHeight(app, cardWidth)

	if app.search == "" then
		local recent = library:recentlyAdded(columns)
		local filterIds = app:tagFilterIds()
		if #filterIds > 0 then
			local matching = {}
			for _, album in ipairs(recent) do
					local keep = false
					for _, track in ipairs(album.tracks) do
							if app.taxonomy:matches(track.path, filterIds, app.tagFilterMatch) then keep = true; break end
						end
					if keep then matching[#matching + 1] = album end
				end
			recent = matching
		end
		local cards = {}
		for _, album in ipairs(recent) do
				---@cast album beat.Album
				cards[#cards + 1] = render.albumCard(app, album, cardWidth,
				{ type = "navigate", page = { kind = "album", id = album.id}},
				{ type = "playAlbum", id = album.id})
			end
		return div():style(sty():column():wrel(1.0):h(cardHeight + theme:px(150)):gap(gap)):children({
		text("Search your library"):style(theme:s():text(theme:type("xxl")):weight("bold")
		:fg(theme:color("text"))),
		text("Artists, albums and tracks are all one field."):style(
		theme:s():text(theme:type("sm")):fg(theme:color("muted"))
		),
		render.section(app, "Recently added"),
		div():style(sty():row():wrel(1.0):h(cardHeight):gap(gap)):children(cards),
		})
	end

	local albums, artists, tracks = app:searchResults(app.search)
	local albumLimit = math.min(#albums, columns * 2)
	local artistLimit = math.min(#artists, 10)
	local trackLimit = math.min(#tracks, 100)
	local albumRows = math.ceil(albumLimit / columns)
	local rowGap = theme:space(16)
	local sectionGap = theme:space(16)
	local sectionHeight = theme:px(24)
	local height = theme:px(40) + filterHeight
	if albumLimit > 0 then
		height = height + sectionGap + sectionHeight + sectionGap + albumRows * cardHeight
		+math.max(0, albumRows - 1) * rowGap
	end
	if artistLimit > 0 then
		height = height + sectionGap + sectionHeight + sectionGap + artistLimit * theme:px(56)
	end
	if trackLimit > 0 then
		height = height + sectionGap + sectionHeight + sectionGap + trackLimit * theme:px(48)
	end

	local children = {
	text("Results for \"" .. app.search .. "\""):style(theme:s():wrel(1.0):text(theme:type("xxl"))
	:weight("bold"):fg(theme:color("text")):ellipsis()),
	}
	if filter ~= nil then children[#children + 1] = filter end

	if albumLimit > 0 then
		children[#children + 1] = render.section(app, "Albums",
		#albums > albumLimit and { type = "navigate",
		page = { kind = "searchAll", category = "albums"}} or nil)
		for rowAt = 1, albumRows do
				local row = {}
				for columnAt = 1, columns do
						local at = (rowAt - 1) * columns + columnAt
						local album = albums[at]
						if album ~= nil and at <= albumLimit then
							row[#row + 1] = render.albumCard(app, album, cardWidth,
							{ type = "navigate", page = { kind = "album", id = album.id}},
							{ type = "playAlbum", id = album.id})
						end
					end
				children[#children + 1] = div():style(sty():row():wrel(1.0):h(cardHeight):gap(gap)):children(row)
			end
	end

	if artistLimit > 0 then
		children[#children + 1] = render.section(app, "Artists",
		#artists > artistLimit and { type = "navigate",
		page = { kind = "searchAll", category = "artists"}} or nil)
		for at, artist in ipairs(artists) do
				if at > artistLimit then break end
				children[#children + 1] = div()
				:style(sty():row():h(theme:px(56)):gap(theme:px(12)):align("center"):radius(theme:radius("sm")))
				:hover(sty():row():h(theme:px(56)):gap(theme:px(12)):align("center"):radius(theme:radius("sm"))
				:bg(theme:color("hover")))
				:onClick({ type = "navigate", page = { kind = "artist", id = artist.id}})
				:children({
				artist.albums[1] ~= nil and render.cover(app, artist.albums[1], theme:px(44),
				theme:radius("full")) or div():style(sty():size(theme:px(44), theme:px(44))
				:radius(theme:radius("full")):bg(theme:color("elevated"))),
				text(artist.name):style(theme:s():text(theme:type("base")):weight("semibold")
				:fg(theme:color("text"))),
				})
			end
	end

	if trackLimit > 0 then
		children[#children + 1] = render.section(app, "Tracks",
		#tracks > trackLimit and { type = "navigate",
		page = { kind = "searchAll", category = "tracks"}} or nil)
		for at, track in ipairs(tracks) do
				if at > trackLimit then break end
				children[#children + 1] = render.trackRow(app, track, at,
				app:currentTrack() ~= nil and app:currentTrack().id == track.id, app.player:isPlaying(),
				{ type = "playTrack", trackId = track.id}, content, true)
			end
	end

	if #albums + #artists + #tracks == 0 then
		height = height + theme:px(300) + sectionGap
		children[#children + 1] = div():style(sty():wrel(1.0):h(theme:px(300))):children({
		render.empty(app, "No results", "Try a different artist, album or title.",
		"Clear search", { type = "clearSearch"}),
		})
	end

	return div():style(sty():column():wrel(1.0):h(height + theme:space(24)):gap(theme:space(16))):children(children)
end

---@param app beat.App
---@param window wonderland.RenderWindow
---@param category "albums"|"artists"|"tracks"
---@return wonderland.Element
local function searchAllPage(app, window, category)
	local theme = app.theme
	local library = app.library
	if library == nil then
		return render.empty(app, "Search your library", "Choose a folder first.", "Choose a folder",
		{ type = "chooseFolder"})
	end
	if app.search == "" then
		return render.empty(app, "Search your library", "Artists, albums and tracks are all one field.",
		nil, nil)
	end

	local albums, artists, tracks = app:searchResults(app.search)
	local items = category == "albums" and albums or category == "artists" and artists or tracks
	local width = pages.contentWidth(app, window.width)
	local filter, filterHeight = searchTagFilter(app, width)
	local gap = theme:space(16)
	local columns = pages.gridColumns(width)
	local cardWidth = math.max(120, math.floor((width - gap * (columns - 1)) / columns))
	local cardHeight = render.albumCardHeight(app, cardWidth)
	local headerHeight = theme:px(58) + filterHeight
	local listStart = headerHeight + gap + (filter ~= nil and gap or 0)
	local rowHeight, perRow
	if category == "albums" then
		rowHeight = cardHeight + gap
		perRow = columns
	elseif category == "artists" then
		rowHeight = theme:px(64)
		perRow = 1
	else
		rowHeight = theme:px(54)
		perRow = 1
	end

	local count = #items
	local totalRows = category == "albums" and math.ceil(count / columns) or count
	local viewport = pages.viewportHeight(app, window.width, window.height)
	local scroll = app:scrollOffset(app:pageKey())
	local first, last, top = app:slices(count, perRow, rowHeight, math.max(0, scroll - listStart), viewport)
	---@cast first number
	---@cast last number
	---@cast top number

	local label = category == "albums" and "All albums" or category == "artists" and "All artists"
	or "All tracks"
	local headerChildren = {
	text(label):style(theme:s():text(theme:type("xxl")):weight("bold"):fg(theme:color("text"))),
	text(util.count(count, category == "albums" and "album" or category == "artists" and "artist" or "track")
	.. " for \"" .. app.search .. "\""):style(theme:s():wrel(1.0):text(theme:type("sm"))
	:fg(theme:color("muted")):ellipsis()),
	}
	if filter ~= nil then headerChildren[#headerChildren + 1] = filter end
	local header = div():style(sty():column():wrel(1.0):h(headerHeight):gap(theme:px(4))):children(headerChildren)

	local list = {}
	if top > 0 then list[#list + 1] = div():style(sty():h(top)) end

	if category == "albums" then
		local row = {}
		for at = first, last do
				local album = albums[at]
				if album ~= nil then
					row[#row + 1] = render.albumCard(app, album, cardWidth,
					{ type = "navigate", page = { kind = "album", id = album.id}},
					{ type = "playAlbum", id = album.id})
				end
				if #row == columns or at == last then
					list[#list + 1] = div():style(sty():row():wrel(1.0):h(rowHeight):gap(gap)):children(row)
					row = {}
				end
			end
	elseif category == "artists" then
		for at = first, last do
				local artist = artists[at]
				if artist ~= nil then
					list[#list + 1] = div()
					:style(sty():row():wrel(1.0):h(rowHeight):gap(theme:px(12)):align("center")
					:radius(theme:radius("sm")))
					:hover(sty():row():wrel(1.0):h(rowHeight):gap(theme:px(12)):align("center")
					:radius(theme:radius("sm")):bg(theme:color("hover")))
					:onClick({ type = "navigate", page = { kind = "artist", id = artist.id}})
					:children({
					artist.albums[1] ~= nil and render.cover(app, artist.albums[1], theme:px(44),
					theme:radius("full")) or div():style(sty():size(theme:px(44), theme:px(44))
					:radius(theme:radius("full")):bg(theme:color("elevated"))),
					text(artist.name):style(theme:s():text(theme:type("base")):weight("semibold")
					:fg(theme:color("text")):ellipsis()),
					})
				end
			end
	else
		for at = first, last do
				local track = tracks[at]
				if track ~= nil then
					list[#list + 1] = div():style(sty():wrel(1.0):h(rowHeight)):children({
					render.trackRow(app, track, at,
					app:currentTrack() ~= nil and app:currentTrack().id == track.id,
					app.player:isPlaying(), { type = "playTrack", trackId = track.id}, width, true),
					})
				end
			end
	end

	local contentHeight = listStart + totalRows * rowHeight
	app.scrollMax = math.max(0, contentHeight - pages.viewportHeight(app, window.width, window.height))
	return div():style(sty():column():wrel(1.0):h(contentHeight):gap(gap)):children({
	header,
	div():style(sty():column():wrel(1.0):h(totalRows * rowHeight)):children(list),
	})
end

---@param app beat.App
---@param playlist beat.Playlist
---@return beat.Track[]
playlistTracks = function(app, playlist)
	if app.library == nil then return {} end
	return app.taxonomy:playlistTracks(playlist, app.library)
end

--- One grapheme from a byte offset: a letter, or the whole picture of an emoji -- its variation
--- selector, skin tone, keycap or joined parts included. Initials count pictures, not bytes.
---@param value string
---@param at number
---@return string cluster
---@return number nextAt
local function firstCluster(value, at)
	local codepoint, nextAt = utf8.decode(value, at)
	if codepoint == nil then return "", at end
	local last = nextAt - 1

	local function modifier(cp)
		return (cp >= 0x0300 and cp <= 0x036F)
		or (cp >= 0xFE00 and cp <= 0xFE0F)
		or (cp >= 0x1F3FB and cp <= 0x1F3FF)
		or cp == 0x20E3
	end

	if codepoint >= 0x1F1E6 and codepoint <= 0x1F1FF and nextAt <= #value then
		local following, after = utf8.decode(value, nextAt)
		if following ~= nil and following >= 0x1F1E6 and following <= 0x1F1FF then
			last, nextAt = after - 1, after
		end
	end

	while nextAt <= #value do
		local cp, after = utf8.decode(value, nextAt)
		if cp == nil or not modifier(cp) then break end
		last, nextAt = after - 1, after
	end

	while nextAt <= #value do
		local cp, after = utf8.decode(value, nextAt)
		if cp ~= 0x200D then break end
		local joined, joinedAfter = utf8.decode(value, after)
		if joined == nil then break end
		last, nextAt = joinedAfter - 1, joinedAfter
		while nextAt <= #value do
			local nextCp, nextAfter = utf8.decode(value, nextAt)
			if nextCp == nil or not modifier(nextCp) then break end
			last, nextAt = nextAfter - 1, nextAfter
		end
	end

	return value:sub(at, last), nextAt
end

--- Two initials at most, one per word: Maximum Overdrive is MO. A word that is a single emoji
--- keeps the whole picture, so a playlist called by its emoji is not cut in half.
---@param name string
---@return string
function pages.playlistInitials(name)
	local initials = {}
	local at = 1
	while at <= #name and #initials < 2 do
		while at <= #name and name:sub(at, at):match("%s") do at = at + 1 end
		if at > #name then break end

		local cluster, nextAt = firstCluster(name, at)
		if cluster ~= "" then
			if #cluster == 1 then cluster = cluster:upper() end
			initials[#initials + 1] = cluster
		end
		at = nextAt
		while at <= #name and not name:sub(at, at):match("%s") do
			local _, after = firstCluster(name, at)
			if after <= at then break end
			at = after
		end
	end
	return table.concat(initials)
end

--- Four tracks spread across the playlist, repeated when the playlist is shorter than four, so
--- the mosaic has the same weight whether it holds four songs or one.
---@param tracks beat.Track[]
---@return beat.Track[]
function pages.playlistMosaicTracks(tracks)
	local picked = {}
	local count = #tracks
	if count <= 4 then
		for at = 1, count do picked[at] = tracks[at] end
		return picked
	end
	for slot = 1, 4 do
			local offset = math.floor((slot - 1) * (count - 1) / 3 + 0.5)
			picked[slot] = tracks[math.min(count, 1 + offset)]
		end
	return picked
end

--- A playlist's square: four evenly spread album pictures behind the playlist's initials. A
--- one-track playlist is one cover, and two or three leave their remaining cells black. The
--- rounded parent clips whatever the cells do, so every playlist has the same outer shape.
---@param app beat.App
---@param tracks beat.Track[]
---@param size number
---@param radius number?
---@param name string
---@return wonderland.Element
playlistArt = function(app, tracks, size, radius, name)
	local theme = app.theme
	local artRadius = radius or theme:radius("sm")
	local picked = pages.playlistMosaicTracks(tracks)
	local initials = pages.playlistInitials(name)
	local badgeSize = math.floor(size * (#initials > 1 and 0.46 or 0.5))
	local fontSize = math.max(10, math.floor(size * (#initials > 1 and 0.32 or 0.38)))
	local badge = div():style(sty():size(badgeSize, badgeSize):radius(badgeSize / 2)
	:offset(math.floor((size - badgeSize) / 2), math.floor((size - badgeSize) / 2))
	:bg(theme:color("bg", 0.72)):align("center"):justify("center"))
	:children(text(initials):style(theme:s():text(fontSize):weight("bold")
	:fg(theme:color("text"))))

	local root = div():style(sty():column():size(size, size):radius(artRadius):bg("#000000"))
	:clip()

	if #picked <= 1 then
		local track = picked[1]
		local album = track ~= nil and app.library ~= nil and app.library:album(track.albumId) or nil
		if album ~= nil then
			---@cast album beat.Album
			root:children({ render.cover(app, album, size, 0)})
		end
		root:children({ badge})
		return root
	end

	local cell = math.floor(size / 2)
	local function cellAt(slot)
		local track = picked[slot]
		local album = track ~= nil and app.library ~= nil and app.library:album(track.albumId) or nil
		if album ~= nil then
			---@cast album beat.Album
			return render.cover(app, album, cell, 0)
		end
		return div():style(sty():size(cell, cell):bg("#000000"))
	end

	root:children({
	div():style(sty():row():h(cell)):children({ cellAt(1), cellAt(2)}),
	div():style(sty():row():h(cell)):children({ cellAt(3), cellAt(4)}),
	badge,
	})
	return root
end

---@param app beat.App
---@param playlist beat.Playlist
---@return wonderland.Element
local function playlistIcons(app, playlist)
	local theme = app.theme
	local children = {}
	if playlist.smart and #playlist.tagIds > 0 then
		children[#children + 1] = ui.icons.element("tag", theme:px(13), theme:color("accent"))
	end
	if playlist.manual then
		children[#children + 1] = ui.icons.element("hand", theme:px(13), theme:color("muted"))
	end
	return div():style(sty():row():w(theme:px(#children * 17)):h(theme:px(16)):gap(theme:px(4))
	:align("center")):children(children)
end

---@param at number
---@return string
local function editedLabel(at)
	if at == nil or at <= 0 then return "Never edited" end
	local now = os.date("*t")
	local then_ = os.date("*t", at)
	if now.year == then_.year and now.month == then_.month and now.day == then_.day then
		return "Edited today"
	end
	return "Edited " .. os.date("%b %d", at)
end

---@param app beat.App
---@param window wonderland.RenderWindow
---@param playlist beat.Playlist
---@return wonderland.Element
local function playlistPage(app, window, playlist)
	local tracks = playlistTracks(app, playlist)
	---@cast tracks beat.Track[]
	local tagNames = {}
	for _, id in ipairs(playlist.tagIds) do
			local tag = app.taxonomy.tagById[id]
			if tag ~= nil then tagNames[#tagNames + 1] = tag.name end
		end
	local duration = 0
	for _, track in ipairs(tracks) do duration = duration + track.duration end

	local subtitle = "Playlist"
	if playlist.autoTagId ~= nil then
		subtitle = "Auto playlist"
	elseif playlist.smart and #tagNames > 0 then
		subtitle = "Smart playlist · " .. table.concat(tagNames, playlist.match == "any" and " or " or " · ")
	end

	local current = app:currentTrack()
	local source = app.player.queue and app.player.queue.source or nil
	local thisPlaylist = current ~= nil and source == "playlist:" .. tostring(playlist.id)
	local playing = app.player:isPlaying()

	local empty = div():style(sty():column():wrel(1.0):h(120):align("center"):justify("center")
	:gap(10)):children({
	ui.icons.element("playlists", app.theme:px(34), app.theme:color("faint")),
	text("This playlist is empty"):style(app.theme:s():text(app.theme:type("lg"))
	:weight("bold"):fg(app.theme:color("text"))),
	text("Use + to add albums, or right-click a track and add it here."):style(
	app.theme:s():text(app.theme:type("sm")):fg(app.theme:color("muted"))),
	})

	return collectionPage(app, window, {
	label = "PLAYLIST",
	icons = playlistIcons(app, playlist),
	cover = function(size) return playlistArt(app, tracks, size, app.theme:radius("lg"), playlist.name) end,
	title = playlist.name,
	subtitle = subtitle,
	meta = util.count(#tracks, "track")
	.. (duration > 0 and (" · " .. util.duration(duration)) or "")
	.. " · " .. editedLabel(playlist.updatedAt),
	playAction = thisPlaylist and { type = "togglePlay"}
	or { type = "playPlaylist", id = playlist.id},
	playIcon = playing and thisPlaylist and "pause" or "play",
	shuffleAction = { type = "playPlaylist", id = playlist.id, shuffle = true},
	addAction = { type = "openPlaylistAdder", id = playlist.id},
	tracks = tracks,
	trackAction = function(track)
		return { type = "playPlaylistTrack", playlistId = playlist.id, trackId = track.id}
	end,
	empty = empty,
	})
end

---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element?
function pages.playlistAdder(app, window)
	local adder = app.playlistAdder
	if adder == nil then return nil end
	local playlist = app.taxonomy:playlist(adder.playlistId)
	if playlist == nil or app.library == nil then return nil end

	local theme = app.theme
	local panelWidth = pages.panelWidth(app, window, 520)
	local rowWidth = panelWidth - theme:px(32)
	local albums
	if adder.query == "" then
		albums = {}
		for at = 1, math.min(8, #app.library.albums) do albums[#albums + 1] = app.library.albums[at] end
	else
		albums = app.library:search(adder.query)
	end
	local rows = {}
	for at = 1, math.min(8, #albums) do
			local album = albums[at]
			---@cast album beat.Album
			rows[#rows + 1] = div():style(sty():row():wrel(1.0):h(theme:px(42)):gap(theme:px(10))
			:pad(0, theme:px(6), 0, theme:px(6)):align("center"):radius(theme:radius("sm")))
			:hover(sty():row():wrel(1.0):h(theme:px(42)):gap(theme:px(10)):pad(0, theme:px(6),
			0, theme:px(6)):align("center"):radius(theme:radius("sm")):bg(theme:color("hover")))
			:onClick({ type = "playlistAddAlbum", id = album.id})
			:children({
			render.cover(app, album, theme:px(32), theme:radius("sm")),
			div():style(sty():column():w(rowWidth - theme:px(78)):gap(0)):children({
			text(album.title):style(theme:s():wrel(1.0):text(theme:type("sm")):weight("semibold")
			:fg(theme:color("text")):ellipsis()),
			text(album.artist):style(theme:s():wrel(1.0):text(theme:type("xs")):fg(theme:color("muted"))
			:ellipsis()),
			}),
			render.iconButton(app, "add", theme:px(26), { type = "playlistAddAlbum", id = album.id}),
			})
		end

	local panelHeight = theme:px(520)
	local panel = div()
	:style(sty():w(panelWidth):h(panelHeight):column():pad(theme:px(16)):gap(theme:px(10))
	:radius(theme:radius("lg")):bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(16), theme:px(42), "#00000080"))
	:onClick({ type = "playlistAdderKeep"})
	:children({
	div():style(sty():row():wrel(1.0):h(theme:px(28)):gap(theme:px(8)):align("center")):children({
	text("Add to " .. playlist.name):style(theme:s():w(rowWidth - theme:px(28)):text(theme:type("lg"))
	:weight("bold"):fg(theme:color("text")):ellipsis()),
	render.iconButton(app, "close", theme:px(28), { type = "closePlaylistAdder"}),
	}),
	dialogField(app, "playlistAddSearch", adder.query, "Search albums",
	function(value) return { type = "playlistAdderQuery", value = value} end,
	function() return nil end),
	div():style(sty():column():wrel(1.0):h(theme:px(8 * 44)):gap(theme:px(2))):children(rows),
	text(#albums > 8 and "Showing the first 8; search to narrow the list."
	or "Click an album to add every track in it."):style(theme:s():text(theme:type("xs"))
	:fg(theme:color("faint"))),
	})

	return div():style(sty():fill():offset(0, 0):z(122):column():align("center"):justify("center")
	:bg(theme:color("overlay"))):onClick({ type = "closePlaylistAdder"}):children({ panel})
end

---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element
local function playlistsPage(app, window)
	local theme = app.theme
	local mobile = pages.mobile(app, window.width)
	local taxonomy = app.taxonomy
	local content = pages.contentWidth(app, window.width)
	local tags = taxonomy:visibleTags()
	---@cast tags beat.Tag[]

	local headerActions = {
	render.button(app, "New playlist", { type = "openPlaylistDialog", smart = false},
	{ primary = true, height = theme:px(30), width = theme:px(128)}),
	render.button(app, "New tag", { type = "openTagDialog"},
	{ height = theme:px(30), width = theme:px(92)}),
	}
	local headerHeight = theme:px(mobile and 92 or 44)
	local actionRow = div():style(sty():row():wrel(1.0):h(theme:px(30)):gap(theme:px(8))
	:align("center"):justify(mobile and "start" or "end")):children(headerActions)
	local title = text("Playlists"):style(theme:s():wrel(1.0):text(theme:type("xxl")):weight("bold")
	:fg(theme:color("text")):ellipsis())
	local header
	if mobile then
		header = div():style(sty():column():wrel(1.0):h(headerHeight):gap(theme:px(10))):children({
		title,
		actionRow,
		})
	else
		header = div():style(sty():row():wrel(1.0):h(headerHeight):gap(theme:px(8))
		:align("center"):justify("space-between")):children({
		title,
		div():style(sty():row():w(theme:px(230)):h(theme:px(30)):gap(theme:px(8))
		:align("center"):justify("end")):children(headerActions),
		})
	end

	local function playlistRow(playlist)
		local tracks = playlistTracks(app, playlist)
		local infoWidth = math.max(theme:px(120), content - theme:px(128))
		local nameStyle = theme:s():text(theme:type("base")):weight("semibold")
		local measured = measuredWidth(app, playlist.name, nameStyle)
		local fallback = textWidth(playlist.name, theme:type("base"), 0.48)
		local nameWidth = math.min(infoWidth - theme:px(50),
		math.max(theme:px(36), math.ceil(math.max(measured or 0, fallback)) + 1))
		local rowStyle = sty():row():wrel(1.0):h(theme:px(72)):pad(0, theme:px(10), 0, theme:px(10))
		:gap(theme:px(12)):align("center"):radius(theme:radius("md")):bg(theme:color("surface"))
		return div():style(rowStyle):hover(sty():row():wrel(1.0):h(theme:px(72)):pad(0,
		theme:px(10), 0, theme:px(10)):gap(theme:px(12)):align("center"):radius(theme:radius("md"))
		:bg(theme:color("hover")))
		:onClick({ type = "navigate", page = { kind = "playlist", id = playlist.id}})
		:onContextMenu(function(_, _, _, _, _, windowX, windowY)
			return { type = "playlistMenu", id = playlist.id, x = windowX, y = windowY}
		end)
		:children({
		playlistArt(app, tracks, theme:px(54), nil, playlist.name),
		div():style(sty():column():w(infoWidth):hrel(1.0):justify("center")
		:gap(theme:px(4))):children({
		-- The type marks sit against the end of the name rather than at the far edge of
		-- the row. The estimate only caps an unusually long name; real names measure short.
		div():style(sty():row():wrel(1.0):h(theme:px(18)):gap(theme:px(6)):align("center")):children({
		text(playlist.name):style(theme:s():w(nameWidth)
		:text(theme:type("base")):weight("semibold"):fg(theme:color("text")):ellipsis()),
		playlistIcons(app, playlist),
		}),
		text(util.count(#tracks, "track") .. " · " .. editedLabel(playlist.updatedAt)):style(
		theme:s():wrel(1.0):h(theme:px(16)):text(theme:type("xs"))
		:fg(theme:color("muted")):ellipsis()),
		}),
		render.iconButton(app, "play", theme:px(30), { type = "playPlaylist", id = playlist.id}),
		})
	end

	local rows = {}
	for _, playlist in ipairs(taxonomy.playlists) do rows[#rows + 1] = playlistRow(playlist) end
	if #rows == 0 then
		rows[#rows + 1] = text("No playlists yet. Tags make smart playlists, or make one by hand."):style(
		theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted"))
		)
	end

	-- Tags are pills whose width comes from what is in them, wrapped by hand because the layout
	-- has no wrap container: two short names fit where one long one takes the row.
	local tagRows = {}
	local tagLine = {}
	local lineWidth = 0
	local pillGap = theme:px(8)
	local pillPadLeft = theme:px(10)
	local pillPadRight = theme:px(6)
	local gaps = theme:px(12)
	local pillBorder = theme:px(1)
	local closeWidth = theme:px(mobile and 28 or 22)
	local nameSize = theme:type(mobile and "sm" or "base")

	local function flushTagLine()
		if #tagLine == 0 then return end
		tagRows[#tagRows + 1] = div():style(sty():row():wrel(1.0):h(theme:px(34))
		:gap(pillGap)):children(tagLine)
		tagLine = {}
		lineWidth = 0
	end

	for _, tag in ipairs(tags) do
			local countText = tostring(tag.count)
			local countStyle = theme:s():text(theme:type("xs"))
			local countFallback = math.floor(#countText * theme:type("xs") * 0.7)
			local countWidth = math.max(theme:px(12),
			math.ceil(math.max(measuredWidth(app, countText, countStyle) or 0, countFallback)) + 1)
			local nameStyle = theme:s():text(nameSize):weight("semibold")
			local nameFallback = textWidth(tag.name, nameSize, 0.54)
			local nameWidth = math.max(theme:px(16), math.ceil(
			math.max(measuredWidth(app, tag.name, nameStyle) or 0, nameFallback)) + 1)
			-- The row break is manual because Wonderland has no wrap container, but each pill's
			-- width comes from the same measured runs the text is drawn with.
			local estimatedWidth = pillPadLeft + pillPadRight + countWidth + nameWidth
			+closeWidth + gaps
			estimatedWidth = math.min(content, math.max(theme:px(64), estimatedWidth))
			nameWidth = math.max(theme:px(16), estimatedWidth - pillPadLeft - pillPadRight
			-countWidth - closeWidth - gaps)

			local editing = app.tagEditId == tag.id
			local pill
			local usedWidth = estimatedWidth
			if editing then
				local editWidth = math.min(content, math.max(estimatedWidth, theme:px(190)))
				usedWidth = editWidth
				local fieldWidth = math.max(theme:px(80),
				editWidth - theme:px(20) - theme:px(24) * 2 - theme:px(8))
				local field = dialogField(app, "tagName", app.tagEditDraft, tag.name,
				function(value) return { type = "tagEditDraft", value = value} end,
				function() return { type = "renameTag"} end, fieldWidth)
				pill = div():style(sty():row():w(editWidth):h(theme:px(34)):gap(theme:px(4))
				:pad(0, theme:px(8), 0, theme:px(8)):align("center"):radius(theme:radius("full"))
				:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))):children({
				field,
				render.iconButton(app, "check", theme:px(24), { type = "renameTag"}),
				render.iconButton(app, "close", theme:px(22), { type = "cancelTagEdit"}),
				})
			else
				pill = div()
				:style(sty():row():w(estimatedWidth):h(theme:px(34)):gap(theme:px(6))
				:pad(0, pillPadRight, 0, pillPadLeft):align("center"):radius(theme:radius("full"))
				:bg(theme:color("elevated")):border(theme:px(1), theme:color("border")))
				:hover(sty():row():w(estimatedWidth):h(theme:px(34)):gap(theme:px(6))
				:pad(0, pillPadRight, 0, pillPadLeft):align("center"):radius(theme:radius("full"))
				:bg(theme:color("hover")):border(theme:px(1), theme:color("border")))
				:onMouseMove(function() return { type = "hoverTag", id = tag.id} end)
				:children({
				text(countText):style(countStyle:w(countWidth):fg(theme:color("faint")):ellipsis()),
				text(tag.name):style(nameStyle:w(nameWidth):fg(theme:color("text")):ellipsis())
				:onClick({ type = "editTag", id = tag.id}),
				div():style(sty():size(closeWidth, theme:px(mobile and 28 or 22))
				:align("center"):justify("center"))
				:onClick({ type = "deleteTag", id = tag.id})
				:children(text("×"):style(theme:s():text(theme:type("lg")):weight("semibold")
				:fg(theme:color("muted")))),
				})
			end

			if lineWidth > 0 and lineWidth + pillGap + usedWidth > content then flushTagLine() end
			tagLine[#tagLine + 1] = pill
			lineWidth = lineWidth + (lineWidth > 0 and pillGap or 0) + usedWidth
		end
	flushTagLine()
	if #tagRows == 0 then
		tagRows[#tagRows + 1] = text("No tags yet. A tag is also a smart playlist."):style(
		theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted"))
		)
	end

	local playlistHeight = #taxonomy.playlists * theme:px(72)
	+math.max(0, #taxonomy.playlists - 1) * theme:px(8)
	local tagHeight = #tagRows * theme:px(34) + math.max(0, #tagRows - 1) * theme:px(8)
	if #taxonomy.playlists == 0 then playlistHeight = theme:px(20) end
	if #tags == 0 then tagHeight = theme:px(20) end
	local height = headerHeight + playlistHeight + theme:px(24) + tagHeight
	+theme:space(18) * 3 + theme:px(24)

	return div():style(sty():column():wrel(1.0):h(height):gap(theme:space(18))):children({
	header,
	div():style(sty():column():wrel(1.0):h(playlistHeight):gap(theme:px(8))):children(rows),
	render.section(app, "Tags"),
	div():style(sty():column():wrel(1.0):h(tagHeight):gap(theme:px(8))):children(tagRows),
	})
end

---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element
local function settingsPage(app, window)
	local theme = app.theme

	local function section(title, copy, rows, height)
		local content = {
		text(title):style(theme:s():text(theme:type("lg")):weight("bold"):fg(theme:color("text"))),
		text(copy):style(theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()),
		}
		for _, row in ipairs(rows) do content[#content + 1] = row end

		return div():style(sty():column():wrel(1.0):h(theme:px(height)):gap(theme:space(12))
		:pad(theme:space(18)):radius(theme:radius("md")):bg(theme:color("surface"))
		:border(theme:px(1), theme:color("border"))):children(content)
	end

	local themeChips = {}
	local narrowTheme = window.width < 560
	for _, name in ipairs(ui.theme.names()) do
			themeChips[#themeChips + 1] = render.button(app,
			name:sub(1, 1):upper() .. name:sub(2),
			{ type = "theme", name = name},
			{ primary = app.settings.theme == name, height = theme:px(30), width = theme:px(narrowTheme and 120 or 92)})
		end
	local themeRow
	if narrowTheme then
		themeRow = div():style(sty():column():h(theme:px(106)):gap(theme:px(8))):children(themeChips)
	else
		themeRow = div():style(sty():row():h(theme:px(32)):gap(theme:px(8))):children(themeChips)
	end

	local accents = {}
	for _, name in ipairs(ui.theme.accents()) do
			local active = app.settings.accent == name
			accents[#accents + 1] = div()
			:style(sty():size(theme:px(narrowTheme and 20 or 28), theme:px(narrowTheme and 20 or 28))
			:radius(theme:radius("full"))
			:bg(ui.theme.accentColour(name))
			:align("center"):justify("center"))
			:onClick({ type = "accent", name = name})
			:children(active and ui.icons.element("check", theme:px(14), ui.theme.accentInk(name)) or div())
		end
	local accentRow = div():style(sty():row():h(theme:px(narrowTheme and 20 or 28))
	:gap(theme:px(narrowTheme and 5 or 8))):children(accents)

	local customButton = div()
	:style(sty():row():w(theme:px(110)):h(theme:px(32)):radius(theme:radius("full"))
	:bg("#000000"):border(theme:px(1), theme:color("border"))
	:align("center"):justify("center"))
	:onClick({ type = "openAccentPicker"})
	:children(text("Custom"):style(theme:s():text(theme:type("sm")):weight("semibold")
	:fg("#f4f6f9")))
	local customRow = div():style(sty():row():h(theme:px(32)):align("center")):children({ customButton})

	local scaleRow = div():style(sty():row():h(theme:px(32))
	:gap(theme:px(narrowTheme and 4 or 8)):align("center")):children({
	text("Scale"):style(theme:s():text(theme:type("sm")):fg(theme:color("muted"))),
	render.button(app, "90%", { type = "uiScale", value = 0.9}, { height = theme:px(28),
	width = theme:px(narrowTheme and 38 or 60), primary = app.settings.uiScale == 0.9}),
	render.button(app, "100%", { type = "uiScale", value = 1}, { height = theme:px(28),
	width = theme:px(narrowTheme and 40 or 62), primary = app.settings.uiScale == 1}),
	render.button(app, "125%", { type = "uiScale", value = 1.25}, { height = theme:px(28),
	width = theme:px(narrowTheme and 40 or 62), primary = app.settings.uiScale == 1.25}),
	})

	local motionRow = div():style(sty():row():h(theme:px(32)):gap(theme:px(8)):align("center")):children({
	text("Motion"):style(theme:s():text(theme:type("sm")):fg(theme:color("muted"))),
	render.button(app, app.settings.reduceMotion and "Motion reduced" or "Reduce motion",
	{ type = "reduceMotion", value = not app.settings.reduceMotion}, { height = theme:px(28),
	width = theme:px(narrowTheme and 130 or 150), primary = app.settings.reduceMotion}),
	})

	local mobileSidebar = pages.mobile(app, window.width)
	local sidebarControls = {
	text(mobileSidebar and "Hidden on phones" or "Width"):style(theme:s():text(theme:type("sm"))
	:fg(theme:color("muted"))),
	}
	if mobileSidebar then
		-- The phone shell uses bottom tabs; sidebar width has no meaning there.
	elseif window.width >= 1040 then
		sidebarControls[#sidebarControls + 1] = render.button(app, "Narrow",
		{ type = "sidebarWidth", width = 220},
		{ height = theme:px(28), width = theme:px(74), primary = app.settings.sidebarWidth == 220})
		sidebarControls[#sidebarControls + 1] = render.button(app, "Balanced",
		{ type = "sidebarWidth", width = 264},
		{ height = theme:px(28), width = theme:px(86), primary = app.settings.sidebarWidth == 264})
		sidebarControls[#sidebarControls + 1] = render.button(app, "Wide",
		{ type = "sidebarWidth", width = 320},
		{ height = theme:px(28), width = theme:px(64), primary = app.settings.sidebarWidth == 320})
		sidebarControls[#sidebarControls + 1] = render.button(app,
		app.settings.sidebarCollapsed and "Expand" or "Collapse", { type = "toggleSidebar"},
		{ height = theme:px(28), width = theme:px(76), primary = app.settings.sidebarCollapsed})
	else
		sidebarControls[#sidebarControls + 1] = text("Icon rail below 1040 px"):style(
		theme:s():text(theme:type("xs")):fg(theme:color("faint"))
		)
	end
	local sidebarRow = div():style(sty():row():h(theme:px(32)):gap(theme:px(8)):align("center"))
	:children(sidebarControls)

	local libraryRows = {
	text(app.settings.root or "No folder chosen"):style(theme:s():text(theme:type("sm"))
	:fg(theme:color("muted")):ellipsis()),
	(function()
		local buttons = {
		render.button(app, "Choose folder…", { type = "chooseFolder"},
		{ primary = true, height = theme:px(32), width = theme:px(narrowTheme and 160 or 150)}),
		render.button(app, "Rescan", { type = "rescan"}, { height = theme:px(32),
		width = theme:px(narrowTheme and 160 or 90)}),
		}
		if narrowTheme then
			return div():style(sty():column():h(theme:px(72)):gap(theme:px(8))):children(buttons)
		end
		return div():style(sty():row():h("auto"):gap(theme:px(8))):children(buttons)
	end)(),
	}
	if app.scanSkipped > 0 then
		libraryRows[#libraryRows + 1] = text(util.count(app.scanSkipped, "file") .. " skipped"):style(
		theme:s():text(theme:type("xs")):fg(theme:color("danger"))
		)
		for at, failure in ipairs(app.scanErrors) do
				if at > 3 then break end
				libraryRows[#libraryRows + 1] = text(path.basename(failure.path) .. " · " .. failure.message):style(
				theme:s():text(theme:type("xs")):fg(theme:color("muted")):ellipsis()
				)
			end
	end

	local audioRow = div():style(sty():row():h(theme:px(32)):gap(theme:px(12)):align("center")):children({
	text("Volume"):style(theme:s():text(theme:type("sm")):fg(theme:color("muted"))),
	render.volume(app, theme:px(narrowTheme and 80 or 200)),
	text(tostring(math.floor((app.settings.isMuted and 0 or app.settings.volume) * 100)) .. "%"):style(
	theme:s():text(theme:type("xs")):fg(theme:color("faint"))
	),
	})

	local lastfm = app.lastfm
	local lastfmTone = lastfm:statusTone()
	local lastfmColour = lastfmTone == "success" and theme:color("success")
	or (lastfmTone == "danger" and theme:color("danger") or theme:color("muted"))
	local lastfmButton
	local lastfmActionWidth
	if lastfm:isConnected() then
		lastfmActionWidth = theme:px(narrowTheme and 92 or 110)
		lastfmButton = render.button(app, "Disconnect", { type = "lastfmDisconnect"},
		{ height = theme:px(28), width = lastfmActionWidth})
	elseif lastfm:isAuthorizing() then
		lastfmActionWidth = theme:px(narrowTheme and 78 or 88) + theme:px(6) + theme:px(70)
		lastfmButton = div():style(sty():row():h(theme:px(28)):gap(theme:px(6))):children({
		render.button(app, "Open page", { type = "lastfmOpenAuth"},
		{ height = theme:px(28), width = theme:px(narrowTheme and 78 or 88)}),
		render.button(app, "Cancel", { type = "lastfmCancel"},
		{ height = theme:px(28), width = theme:px(70)}),
		})
	else
		lastfmActionWidth = theme:px(narrowTheme and 84 or 96)
		lastfmButton = render.button(app, "Connect", { type = "lastfmConnect"},
		{ primary = true, height = theme:px(28), width = lastfmActionWidth})
	end

	local lastfmStatusWidth = math.max(theme:px(80),
	pages.contentWidth(app, window.width) - theme:space(18) * 2 - lastfmActionWidth - theme:px(10))
	local lastfmStatusRow = div():style(sty():row():wrel(1.0):h(theme:px(28)):gap(theme:px(10))
	:align("center")):children({
	text(lastfm:statusText()):style(theme:s():w(lastfmStatusWidth):text(theme:type("xs"))
	:fg(lastfmColour):ellipsis()),
	lastfmButton,
	})

	local lastfmToggleRow = div():style(sty():row():h(theme:px(32)):gap(theme:px(8)):align("center"))
	:children({
	text("Scrobbling"):style(theme:s():text(theme:type("sm")):fg(theme:color("muted"))),
	render.button(app, app.settings.lastfmEnabled and "Enabled" or "Paused",
	{ type = "lastfmEnabled", value = not app.settings.lastfmEnabled},
	{ height = theme:px(28), width = theme:px(narrowTheme and 76 or 88),
	primary = app.settings.lastfmEnabled}),
	})

	local lastfmRows = { lastfmStatusRow, lastfmToggleRow}
	local lastfmHeight = 176

	local githubButtons = {
	render.button(app, "GitHub", { type = "openURL", url = GITHUB},
	{ icon = "github", primary = true, height = theme:px(32),
	width = theme:px(narrowTheme and 160 or 124)}),
	render.button(app, "Issues", { type = "openURL", url = GITHUB .. "/issues"},
	{ height = theme:px(32), width = theme:px(narrowTheme and 160 or 92)}),
	}
	local githubRow
	if narrowTheme then
		githubRow = div():style(sty():column():h(theme:px(72)):gap(theme:px(8))):children(githubButtons)
	else
		githubRow = div():style(sty():row():h(theme:px(32)):gap(theme:px(8))):children(githubButtons)
	end

	local appearanceHeight = (narrowTheme and 342 or 268) + 32 + 12
	local libraryHeight = (narrowTheme and 210 or 170)
	+(app.scanSkipped > 0 and (12 + math.min(#app.scanErrors, 3) * 16) or 0)
	local aboutHeight = narrowTheme and 196 or 156
	return div():style(sty():column():wrel(1.0):h(theme:px(32 + appearanceHeight + 136 + libraryHeight
	+134 + lastfmHeight + aboutHeight + 6 * 16 + 24))
	:gap(theme:space(16))):children({
	text("Settings"):style(theme:s():text(theme:type("xxl")):weight("bold"):fg(theme:color("text"))),
	section("Appearance", "Theme, accent, custom colour, scale and motion.",
	{ themeRow, accentRow, customRow, scaleRow, motionRow}, appearanceHeight),
	section("Sidebar", "Width and rail behaviour.", { sidebarRow}, 136),
	section("Library", "Where the library is read from.", libraryRows, libraryHeight),
	section("Audio", "Output volume.", { audioRow}, 134),
	section("Last.fm", "Authorize your account to send now-playing updates and scrobbles.", lastfmRows,
	lastfmHeight),
	section("About", "beat 0.1 · local files only · wonderland + treble · Ionicons", {
	githubRow,
	}, aboutHeight),
	})
end

---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element
local function foldersPage(app, window)
	local theme = app.theme
	local mobile = pages.mobile(app, window.width)
	local pad = pages.pad(app, window.width)
	local entries = app.folderEntries
	local rows = {}

	local choose = render.button(app, "Choose folder…", { type = "chooseFolder"},
	{ primary = true, height = theme:px(30), width = theme:px(142)})
	local up = render.button(app, "Up", { type = "folderUp"},
	{ height = theme:px(30), width = theme:px(48)})
	local select = render.button(app, "Select this folder", { type = "folderSelect", path = app.folderPath},
	{ height = theme:px(30), width = theme:px(150)})
	local cancel = app.library ~= nil and render.button(app, "Cancel", { type = "cancelFolders"},
	{ height = theme:px(30), width = theme:px(80)}) or nil

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

	for _, entry in ipairs(entries) do
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
	text(app.folderPath or ""):style(theme:s():wrel(1.0):h(theme:px(24)):pad(theme:px(5), theme:px(8),
	theme:px(5), theme:px(8)):radius(theme:radius("sm")):bg(theme:color("surface"))
	:text(theme:type("xs")):fg(theme:color("faint")):ellipsis())
	:input({
	name = "folderPath",
	value = app.folderPath or "",
	oninput = function() end,
	onsubmit = function(value) return { type = "folderGo", path = value} end,
	}),
	})
	if app.folderError ~= nil then
		content:children(text(app.folderError):style(
		theme:s():text(theme:type("xs")):fg(theme:color("danger"))
		))
	end
	content:children(div():style(sty():column():wrel(1.0):h(theme:px(320)):pad(0, 0, 0, 0)
	:bar(theme:px(8), theme:px(40), theme:color("faint")))
	:scroll(app:scrollOffset("folders"))
	:onScroll(function(by, to)
		return { type = "scroll", by = by, to = to}
	end):children(rows))

	return div():style(sty():column():wrel(1.0):h(theme:px(540)):pad(theme:space(20), pad, theme:space(20), pad)
	:gap(theme:space(16))):children({ content})
end

-- ────────────────────────────────────────────────────────────────
-- overlays
-- ────────────────────────────────────────────────────────────────

---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element? overlay
function pages.expanded(app, window)
	if not app.expanded then return nil end
	local theme = app.theme
	local mobile = pages.mobile(app, window.width)
	local stacked = mobile and window.height >= theme:px(560)
	local track = app:currentTrack()
	---@type beat.Album?
	local album
	if track ~= nil and app.library ~= nil then album = app.library:album(track.albumId) end
	local margin = mobile and theme:space(16)
	or math.max(theme:space(10), math.min(theme:space(28),
	math.floor(window.width * 0.03), math.floor(window.height * 0.03)))
	local availableWidth = window.width - margin * 2
	local availableHeight = window.height - margin * 2
	local mainPad = math.min(theme:space(32), math.max(theme:px(12), math.floor(availableHeight * 0.06)))
	local gap = theme:space(32)
	local desiredProgress = window.width >= 1240 and theme:px(600) or theme:px(380)
	local compact = availableHeight < theme:px(430)
	local stageGap = compact and theme:px(6) or theme:px(10)

	local header = div():style(sty():row():wrel(1.0):h(theme:px(36)):justify("end")
	:align("center"):offset(0, 0):z(110)):children({
	render.iconButton(app, "chevronDown", theme:px(34),
	{ type = "expandNowPlaying", open = false}),
	})
	local contentChildren = {}

	if track ~= nil and album ~= nil then
		---@cast track beat.Track
		---@cast album beat.Album
		local coverSize
		local progressWidth
		if stacked then
			coverSize = math.min(theme:px(220), math.floor(availableWidth * 0.58),
			math.floor(availableHeight * 0.34))
			progressWidth = math.max(theme:px(160), availableWidth - mainPad * 2)
		else
			coverSize = math.min(theme:px(390), math.floor(availableWidth * 0.27),
			math.floor(availableHeight * 0.43))
			local maxText = availableWidth - coverSize - gap
			if maxText < theme:px(180) then
				coverSize = math.max(theme:px(64), availableWidth - gap - theme:px(180))
				maxText = availableWidth - coverSize - gap
			end
			progressWidth = math.max(theme:px(160), math.min(desiredProgress, maxText))
		end
		local stageHeight = math.min(theme:px(340), math.max(theme:px(220),
		availableHeight - theme:px(34) - mainPad * 2))

		local cover = div():style(sty():size(coverSize, coverSize):shadow(0, 12, 20, "#00000060"))
		:onClick({ type = "navigate", page = { kind = "album", id = album.id}})
		:onContextMenu(function(_, _, _, _, _, windowX, windowY)
			return { type = "albumMenu", id = album.id, x = windowX, y = windowY}
		end)
		:children(render.cover(app, album, coverSize, theme:radius("lg"), true))
		local transport = math.max(0.7, math.min(1, progressWidth / theme:px(240)))
		local controlGap = theme:px(10 * transport)
		local textRows = {
		text(track.title):style(theme:s():w(progressWidth)
		:text(theme:type(mobile and "xxl" or "hero")):weight("bold")
		:fg(theme:color("text")):ellipsis()),
		text(album.title .. "  ·  " .. track.artist):style(theme:s():w(progressWidth)
		:text(theme:type("lg")):weight("medium"):fg(theme:color("muted")):ellipsis()),
		}
		local repeatIcon = app.player.queue and app.player.queue.repeatMode == "one"
		and "repeatOne" or "repeat"
		local repeatActive = app.player.queue and app.player.queue.repeatMode ~= "off"
		local toolSize = theme:px(28)
		local toolGap = theme:px(4)
		local toolGroupWidth = toolSize * 2 + toolGap
		textRows[#textRows + 1] = div():style(sty():row():wrel(1.0):h(theme:px(34))
		:align("center"):justify("space-between")):children({
		div():style(sty():row():w(toolGroupWidth):h(theme:px(34)):gap(toolGap)
		:align("center")):children({
		render.iconButton(app, "playlists", toolSize, { type = "toggleQueue"}, app.queueOpen),
		render.moreButton(app, toolSize, { type = "toggleMore"}, app.moreOpen),
		}),
		div():style(sty():row():w(toolGroupWidth):h(theme:px(34)):gap(toolGap)
		:align("center")):children({
		render.iconButton(app, "shuffle", toolSize, { type = "shuffle"},
		app.player.queue and app.player.queue.shuffle),
		render.iconButton(app, repeatIcon, toolSize, { type = "repeat"}, repeatActive),
		}),
		})
		textRows[#textRows + 1] = render.progress(app, track, app.player, progressWidth)
		local controlHeight = theme:px(54 * transport)
		local controlChildren = {
		render.volumeButton(app, theme:px(28 * transport)),
		div():style(sty():row():gap(controlGap):align("center"):justify("center")):children({
		render.iconButton(app, "previous", theme:px(30 * transport), { type = "previous"}),
		div():style(sty():size(theme:px(54 * transport), theme:px(54 * transport))
		:radius(theme:radius("full")):bg(theme:color("accent"))
		:align("center"):justify("center"))
		:onClick({ type = "togglePlay"})
		:children(ui.icons.element(app.player:isPlaying() and "pause" or "play",
		theme:px(24 * transport), theme.accentInk)),
		render.iconButton(app, "next", theme:px(30 * transport), { type = "next"}),
		}),
		render.equalizerButton(app, theme:px(28 * transport),
		{ type = "toggleEqualizer"}, app.equalizerOpen),
		}
		if app.volumeOpen then
			local panelHeight = theme:px(44)
			controlChildren[#controlChildren + 1] = render.volumeBubble(app, {
			width = theme:px(190),
			height = panelHeight,
			x = 0,
			y = compact and (-panelHeight - theme:px(8)) or (controlHeight + theme:px(8)),
			})
		end
		local controls = div():style(sty():row():wrel(1.0):h(controlHeight)
		:align("center"):justify("space-between")):children(controlChildren)
		textRows[#textRows + 1] = controls
		local stackedTextHeight = theme:type("xxl") + theme:type("lg")
		+theme:px(34 + 18) + controlHeight + stageGap * 4
		local main
		if stacked then
			main = div():style(sty():h(availableHeight)
			:column():align("center"):justify("center"):gap(theme:space(16)):pad(mainPad, 0, mainPad, 0))
			main:children({
			cover,
			div():style(sty():column():h(stackedTextHeight):gap(stageGap)
			:w(progressWidth)):children(textRows),
			})
		else
			main = div():style(sty():h(availableHeight)
			:row():align("center"):justify("center"):gap(gap):pad(mainPad, 0, mainPad, 0))
			main:children({
			cover,
			div():style(sty():column():h(stageHeight):justify("center"):gap(stageGap)
			:w(progressWidth)):children(textRows),
			})
		end
		contentChildren[#contentChildren + 1] = main
	end
	contentChildren[#contentChildren + 1] = header

	-- The FFT belongs to the window, not to the padded content: the content's gutter only
	-- positions the controls, while the background bars run to every edge.
	local content = div():style(sty():fill():column():pad(margin, margin, margin, margin)
	:gap(theme:space(16))):children(contentChildren)

	return div()
	:style(sty():fill():offset(0, 0):z(100):column():bg(theme:color("bg"))
	:fg(theme:color("text")):font(theme.fontFamily))
	:canvas(function(canvas)
		render.spectrumBackground(app, canvas, { intensity = 0.28, reach = 0.72})
	end)
	:children({ content})
end

---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element? overlay
function pages.toasts(app, window)
	if #app.toasts == 0 then return nil end
	local theme = app.theme
	local now = wonderland.time.now()
	local children = {}
	local top = theme:px(76)
	local scanCard = (app.scan ~= nil and app.scanIslandOpen and app.library ~= nil
	and #app.library.tracks > 0) or app.scanSummary ~= nil
	if scanCard then top = top + theme:px(112) + theme:space(12) end

	for index, toast in ipairs(app.toasts) do
			local enter = app.motion.reduce and 1
			or ui.motion.progress(toast.at, 0.18, now, ui.motion.ease.outCubic)
			local life = toast.tone == "error" and 8 or 4.5
			local exit = app.motion.reduce and 1
			or 1 - ui.motion.progress(toast.at + life - 0.3, 0.3, now, ui.motion.ease.inCubic)
			-- Both the fade and the lift are quantised so they reuse styles instead of interning
			-- one per frame.
			local enterStep = math.floor(enter * 16 + 0.5) / 16
			local exitStep = math.floor(exit * 16 + 0.5) / 16
			local alpha = math.min(enterStep, exitStep)
			local lift = (1 - enterStep) * theme:px(8) - (1 - exitStep) * theme:px(8)
			local tone = toast.tone == "error" and theme:color("danger", alpha)
			or theme:color("accent", alpha)

			children[#children + 1] = div()
			:style(sty():w(320):h(theme:px(48)):row():pad(theme:px(12), theme:px(14), theme:px(12), theme:px(14))
			:gap(theme:px(10)):align("center"):radius(theme:radius("sm"))
			:bg(theme:color("elevated", alpha))
			:offset(math.max(theme:space(8), window.width - 320 - theme:space(24)),
			top + (index - 1) * (theme:px(48) + theme:px(8)) + lift)
			:shadow(0, theme:px(8), theme:px(24), "#00000040"))
			:onClick({ type = "dismissToast", at = toast.at})
			:children({
			ui.icons.element(toast.tone == "error" and "close" or "check", theme:px(18), tone),
			text(toast.text):style(theme:s():wrel(1.0):text(theme:type("sm"))
			:fg(theme:color("text", alpha)):ellipsis()),
			})
		end

	return div():style(sty():fill():offset(0, 0):z(90)):children(children)
end

--- The sort choices, anchored under the library's sort button.
---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element?
function pages.sortMenu(app, window)
	if not app.sortOpen or app.page.kind ~= "library" then return nil end
	local theme = app.theme
	local panelWidth = theme:px(210)
	local rows = {}
	for _, option in ipairs(SORT_OPTIONS) do
			local active = app.settings.sort == option.key
			local rowStyle = sty():row():wrel(1.0):h(theme:px(32)):gap(theme:px(8)):align("center")
			:justify("space-between"):pad(0, theme:px(10), 0, theme:px(10)):radius(theme:radius("sm"))
			:fg(active and theme.accentInk or theme:color("text"))
			if active then rowStyle:bg(theme:color("accent")) end
			rows[#rows + 1] = div()
			:style(rowStyle)
			:hover(sty():row():wrel(1.0):h(theme:px(32)):gap(theme:px(8)):align("center")
			:justify("space-between"):pad(0, theme:px(10), 0, theme:px(10)):radius(theme:radius("sm"))
			:bg(theme:color("accent")):fg(theme.accentInk))
			:onClick({ type = "sort", value = option.key})
			:children({
			text(option.label):style(theme:s():w(theme:px(150)):text(theme:type("sm")):ellipsis()),
			active and ui.icons.element("check", theme:px(15), theme.accentInk) or div(),
			})
		end

	local panel = div()
	:style(sty():w(panelWidth):column():h(theme:px(#SORT_OPTIONS * 34 + 12)):pad(theme:px(6))
	:gap(theme:px(2)):radius(theme:radius("md")):bg(theme:color("elevated"))
	:border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(12), theme:px(32), "#00000070"))
	:children(rows)

	return div()
	:style(sty():fill():offset(0, 0):z(70):column():align("end")
	:pad(theme:px(window.width < 560 and 156 or 138), pages.pad(app), 0, 0))
	:onClick({ type = "sortMenu", value = false})
	:children({ panel})
end

--- A small confirmable colour grid, opened by the Appearance tab's Custom button.
---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element?
function pages.accentPicker(app, window)
	if not app.accentPickerOpen then return nil end
	local theme = app.theme
	local draft = app.accentDraft or ui.theme.accentColour(app.settings.accent)
	local narrow = window.width < 560
	local columns = narrow and 6 or 12
	local rows = math.ceil(#ACCENT_GRID / columns)
	local swatch = theme:px(narrow and 24 or 26)
	local gap = theme:px(narrow and 6 or 8)
	local pad = theme:px(20)
	local headerHeight = theme:px(44)
	local footerHeight = theme:px(36)
	local gridWidth = columns * swatch + (columns - 1) * gap
	local gridHeight = rows * swatch + (rows - 1) * gap
	local panelWidth = gridWidth + pad * 2
	local panelHeight = pad * 2 + headerHeight + gridHeight + footerHeight + theme:px(24)

	local cells = {}
	for rowAt = 1, rows do
			local row = {}
			for columnAt = 1, columns do
					local colour = ACCENT_GRID[(rowAt - 1) * columns + columnAt]
					if colour ~= nil then
						local selected = draft:lower() == colour
						row[#row + 1] = div()
						:style(sty():size(swatch, swatch):radius(theme:radius("sm"))
						:bg(colour):align("center"):justify("center")
						:border(theme:px(selected and 2 or 1),
						selected and theme:color("text") or theme:color("border")))
						:onClick({ type = "pickAccent", value = colour})
						:children(selected and ui.icons.element("check", theme:px(14),
						ui.theme.accentInk(colour)) or div())
					end
				end
			cells[#cells + 1] = div():style(sty():row():h(swatch):gap(gap)):children(row)
		end

	local name = text("Custom accent"):style(theme:s():text(theme:type("lg")):weight("bold")
	:fg(theme:color("text")))
	local hex = text(draft:upper()):style(theme:s():text(theme:type("xs")):fg(theme:color("muted")))
	local header = div():style(sty():row():h(headerHeight):gap(theme:px(10)):align("center")):children({
	div():style(sty():size(theme:px(36), theme:px(36)):radius(theme:radius("full"))
	:bg(draft):border(theme:px(1), theme:color("border"))),
	div():style(sty():column():wrel(1.0):gap(theme:px(1))):children({ name, hex}),
	})

	local panel = div()
	:style(sty():w(panelWidth):h(panelHeight):column():pad(pad):gap(theme:px(12))
	:radius(theme:radius("lg")):bg(theme:color("elevated"))
	:border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(16), theme:px(42), "#00000080"))
	:onClick({ type = "accentPickerKeep"})
	:children({
	header,
	div():style(sty():column():h(gridHeight):gap(gap)):children(cells),
	div():style(sty():row():h(footerHeight):gap(theme:px(8)):align("center")
	:justify("end")):children({
	render.button(app, "Cancel", { type = "closeAccentPicker"},
	{ height = theme:px(32), width = theme:px(82)}),
	div():style(sty():row():w(theme:px(112)):h(theme:px(32))
	:radius(theme:radius("full")):bg(draft):align("center"):justify("center"))
	:onClick({ type = "confirmAccent"})
	:children(text("Use colour"):style(theme:s():text(theme:type("sm"))
	:weight("semibold"):fg(ui.theme.accentInk(draft)))),
	}),
	})

	return div()
	:style(sty():fill():offset(0, 0):z(110):column():align("center"):justify("center")
	:bg(theme:color("overlay")))
	:onClick({ type = "closeAccentPicker"})
	:children({ panel})
end

--- The tags on the track that is playing, as toggles. Clicking the dark area dismisses it;
--- clicking the panel itself does not.
---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element?
function pages.tagPicker(app, window)
	if not app.tagPickerOpen then return nil end
	local track = app.tagTrackId ~= nil and app.library ~= nil
	and app.library:track(app.tagTrackId) or app:currentTrack()
	if track == nil then return nil end
	local theme = app.theme
	local tags = app.taxonomy:visibleTags()
	local selected = {}
	local assigned = app.taxonomy.byPath[track.path]
	if assigned ~= nil then
		for id in pairs(assigned) do selected[id] = true end
	end

	local panelWidth = pages.panelWidth(app, window, 380)
	local pad = theme:px(18)
	local content = panelWidth - pad * 2
	local pills = tagPills(app, tags, selected, function(tag)
		return { type = "toggleTrackTag", id = tag.id}
	end, content, 2)

	local children = {
	text("Tags on this track"):style(theme:s():text(theme:type("lg")):weight("bold")
	:fg(theme:color("text"))),
	text(track.title):style(theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted"))
	:ellipsis()),
	}
	if pills ~= nil then children[#children + 1] = pills
	else children[#children + 1] = text("No tags yet. Create one to start grouping this track."):style(
		theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted"))
		) end
	children[#children + 1] = div():style(sty():row():h(theme:px(32)):gap(theme:px(8))
	:align("center"):justify("end")):children({
	render.button(app, "New tag", { type = "openTagDialog"}, { height = theme:px(30), width = theme:px(92)}),
	})
	local pillRows = math.max(1, math.min(8, #tags))
	local pillsHeight = pills ~= nil and (math.ceil(pillRows / 2) * theme:px(28)
	+math.max(0, math.ceil(pillRows / 2) - 1) * theme:px(8)
	+(#tags > 8 and theme:px(18) or 0)) or theme:px(20)
	local panelHeight = pad * 2 + theme:px(24) + theme:px(20) + pillsHeight + theme:px(32)
	+theme:px(10) * 3

	local panel = div()
	:style(sty():w(panelWidth):h(panelHeight):column():pad(pad):gap(theme:px(10)):radius(theme:radius("lg"))
	:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(16), theme:px(42), "#00000080"))
	:onClick({ type = "tagPickerKeep"})
	:children(children)

	return div():style(sty():fill():offset(0, 0):z(115):column():align("center"):justify("center")
	:bg(theme:color("overlay"))):onClick({ type = "closeTagPicker"}):children({ panel})
end

---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element?
function pages.tagDialog(app, window)
	if not app.tagDialogOpen then return nil end
	local theme = app.theme
	local panelWidth = pages.panelWidth(app, window, 360)
	local pad = theme:px(18)
	local panelHeight = pad * 2 + theme:px(24) + theme:px(20) + theme:px(34) + theme:px(32)
	+theme:px(12) * 3
	local panel = div()
	:style(sty():w(panelWidth):h(panelHeight):column():pad(pad):gap(theme:px(12)):radius(theme:radius("lg"))
	:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(16), theme:px(42), "#00000080"))
	:onClick({ type = "tagDialogKeep"})
	:children({
	text("New tag"):style(theme:s():text(theme:type("lg")):weight("bold"):fg(theme:color("text"))),
	text("Tag tracks so playlists and search can find them."):style(
	theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()),
	dialogField(app, "newTag", app.tagDraft, "Tag name",
	function(value) return { type = "tagDraft", value = value} end,
	function() return { type = "createTag"} end),
	div():style(sty():row():h(theme:px(32)):gap(theme:px(8)):align("center"):justify("end")):children({
	render.button(app, "Cancel", { type = "closeTagDialog"}, { height = theme:px(30), width = theme:px(80)}),
	render.button(app, "Create", { type = "createTag"}, { primary = true, height = theme:px(30),
	width = theme:px(86)}),
	}),
	})

	return div():style(sty():fill():offset(0, 0):z(120):column():align("center"):justify("center")
	:bg(theme:color("overlay"))):onClick({ type = "closeTagDialog"}):children({ panel})
end

--- The one destructive tag action asks first: a tag that has never been put on a track goes
--- straight away, but one that has is also what its automatic playlist is built from. The
--- dialog says how many tracks are involved before anything is removed.
---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element?
function pages.tagDeleteDialog(app, window)
	local id = app.tagDeleteId
	if id == nil then return nil end
	local tag = app.taxonomy.tagById[id]
	if tag == nil then return nil end

	local theme = app.theme
	local panelWidth = pages.panelWidth(app, window, 380)
	local pad = theme:px(18)
	local panelHeight = theme:px(154)

	local cancelStyle = sty():w(theme:px(80)):h(theme:px(30)):radius(theme:radius("full"))
	:align("center"):justify("center"):bg(theme:color("surface"))
	:border(theme:px(1), theme:color("border"))
	local cancelHover = sty():w(theme:px(80)):h(theme:px(30)):radius(theme:radius("full"))
	:align("center"):justify("center"):bg(theme:color("hover"))
	:border(theme:px(1), theme:color("border"))
	local deleteStyle = sty():w(theme:px(88)):h(theme:px(30))
	:radius(theme:radius("full")):align("center"):justify("center"):bg(theme:color("danger"))
	local deleteHover = sty():w(theme:px(88)):h(theme:px(30))
	:radius(theme:radius("full")):align("center"):justify("center"):bg(theme:color("danger"))
	:bright(1.08)

	local panel = div()
	:style(sty():w(panelWidth):h(panelHeight):column():pad(pad):gap(theme:px(10))
	:radius(theme:radius("lg")):bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(16), theme:px(42), "#00000080"))
	:onClick({ type = "tagDeleteKeep"})
	:children({
	text("Delete “" .. tag.name .. "”?"):style(theme:s():wrel(1.0):text(theme:type("lg"))
	:weight("bold"):fg(theme:color("text")):ellipsis()),
	text("It is used on " .. util.count(tag.count, "track") .. "."):style(
	theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()),
	text("Its automatic playlist will be deleted too."):style(
	theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()),
	div():style(sty():row():wrel(1.0):h(theme:px(32)):gap(theme:px(8)):align("center")
	:justify("end")):children({
	div():style(cancelStyle):hover(cancelHover):onClick({ type = "cancelDeleteTag"})
	:children(text("Cancel"):style(theme:s():text(theme:type("sm")):weight("semibold")
	:fg(theme:color("text")))),
	div():style(deleteStyle):hover(deleteHover):onClick({ type = "confirmDeleteTag"})
	:children(text("Delete"):style(theme:s():text(theme:type("sm")):weight("semibold")
	:fg(theme:color("bg")))),
	}),
	})

	return div():style(sty():fill():offset(0, 0):z(124):column():align("center"):justify("center")
	:bg(theme:color("overlay"))):onClick({ type = "cancelDeleteTag"}):children({ panel})
end

---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element?
function pages.playlistDialog(app, window)
	local dialog = app.playlistDialog
	if dialog == nil then return nil end
	local theme = app.theme
	local tags = app.taxonomy:visibleTags()
	local panelWidth = pages.panelWidth(app, window, 440)
	local pad = theme:px(18)
	local content = panelWidth - pad * 2
	local children = {
	text("New playlist"):style(
	theme:s():text(theme:type("lg")):weight("bold"):fg(theme:color("text"))),
	text("Tags add tracks automatically; you can still add the rest by hand."):style(
	theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()),
	dialogField(app, "playlistName", dialog.name, "Playlist name",
	function(value) return { type = "playlistDraft", value = value} end,
	function() return { type = "createPlaylist"} end),
	}

	local pills = tagPills(app, tags, dialog.tagIds, function(tag)
		return { type = "playlistDraftTag", id = tag.id}
	end, content, pages.mobile(app, window.width) and 2 or 3)
	children[#children + 1] = pills or text("Create a tag to make this playlist smart too."):style(
	theme:s():text(theme:type("sm")):fg(theme:color("faint")))
	children[#children + 1] = div():style(sty():row():h(theme:px(28)):gap(theme:px(8))
	:align("center")):children({
	text("Match"):style(theme:s():text(theme:type("xs")):fg(theme:color("muted"))),
	render.button(app, "All tags", { type = "playlistDraftMatch", value = "all"},
	{ height = theme:px(26), width = theme:px(82), primary = dialog.match == "all"}),
	render.button(app, "Any tag", { type = "playlistDraftMatch", value = "any"},
	{ height = theme:px(26), width = theme:px(82), primary = dialog.match == "any"}),
	})

	children[#children + 1] = div():style(sty():row():h(theme:px(32)):gap(theme:px(8))
	:align("center"):justify("end")):children({
	render.button(app, "Cancel", { type = "closePlaylistDialog"}, { height = theme:px(30),
	width = theme:px(80)}),
	render.button(app, "Create", { type = "createPlaylist"}, { primary = true, height = theme:px(30),
	width = theme:px(86)}),
	})

	local tagRows = math.max(1, math.ceil(math.min(#tags, 12) / 3))
	local pillsHeight = #tags > 0 and (tagRows * theme:px(28) + math.max(0, tagRows - 1) * theme:px(8)
	+(#tags > 12 and theme:px(18) or 0)) or theme:px(20)
	local rowCount = dialog.smart and 6 or 4
	local panelHeight = pad * 2 + theme:px(24) + theme:px(20) + theme:px(34) + theme:px(32)
	+theme:px(10) * (rowCount - 1) + (dialog.smart and pillsHeight + theme:px(28) or 0)
	local panel = div()
	:style(sty():w(panelWidth):h(panelHeight):column():pad(pad):gap(theme:px(10)):radius(theme:radius("lg"))
	:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(16), theme:px(42), "#00000080"))
	:onClick({ type = "playlistDialogKeep"})
	:children(children)

	return div():style(sty():fill():offset(0, 0):z(120):column():align("center"):justify("center")
	:bg(theme:color("overlay"))):onClick({ type = "closePlaylistDialog"}):children({ panel})
end

---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element?
function pages.playlistPicker(app, window)
	local picker = app.playlistPicker
	if picker == nil then return nil end
	local theme = app.theme
	local manual = {}
	for _, playlist in ipairs(app.taxonomy.playlists) do
			manual[#manual + 1] = playlist
		end
	local rows = {}
	for _, playlist in ipairs(manual) do
			local count = app.library ~= nil and #app.taxonomy:playlistTracks(playlist, app.library) or 0
			rows[#rows + 1] = div()
			:style(sty():row():wrel(1.0):h(theme:px(38)):pad(0, theme:px(10), 0, theme:px(10))
			:gap(theme:px(8)):radius(theme:radius("sm")):align("center"):justify("space-between"))
			:hover(sty():row():wrel(1.0):h(theme:px(38)):pad(0, theme:px(10), 0, theme:px(10))
			:gap(theme:px(8)):radius(theme:radius("sm")):align("center"):justify("space-between")
			:bg(theme:color("hover")))
			:onClick({ type = "addToPlaylist", playlistId = playlist.id})
			:children({
			text(playlist.name):style(theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("text"))
			:ellipsis()),
			text(util.count(count, "track")):style(theme:s():text(theme:type("xs")):fg(theme:color("muted"))),
			})
		end
	if #rows == 0 then
		rows[#rows + 1] = text("No playlists yet. Create one on the Playlists page."):style(
		theme:s():wrel(1.0):text(theme:type("xs")):fg(theme:color("muted"))
		)
	end

	local panelHeight = theme:px(20) + theme:px(16) + math.max(0, #rows) * theme:px(38)
	+math.max(0, #rows) * theme:px(4) + theme:px(4)
	local panel = div()
	:style(sty():w(pages.panelWidth(app, window, 330)):h(panelHeight):column():pad(theme:px(10))
	:gap(theme:px(4)):radius(theme:radius("md"))
	:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(12), theme:px(30), "#00000080"))
	:onClick({ type = "playlistPickerKeep"})
	:children({
	text(picker.kind == "album" and "Add album to playlist" or "Add track to playlist"):style(
	theme:s():text(theme:type("xs")):weight("bold"):fg(theme:color("muted"))),
	})
	for _, row in ipairs(rows) do panel:children({ row}) end

	return div():style(sty():fill():offset(0, 0):z(121):column():align("center"):justify("center")
	:bg(theme:color("overlay"))):onClick({ type = "closePlaylistPicker"}):children({ panel})
end

---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element?
function pages.trackMenu(app, window)
	local menu = app.trackMenu
	local track = menu ~= nil and app.library ~= nil and app.library:track(menu.id) or nil
	if menu == nil or track == nil then return nil end
	local theme = app.theme
	local width = theme:px(210)
	local rowHeight = theme:px(34)
	local height = theme:px(8 * 2 + 34 * 2 + 2)
	local margin = theme:px(8)
	local x = math.max(margin, math.min(menu.x, window.width - width - margin))
	local y = math.max(margin, math.min(menu.y, window.height - height - margin))
	local rows = {}
	local function entry(label, action)
		rows[#rows + 1] = div()
		:style(sty():row():wrel(1.0):h(rowHeight):pad(0, theme:px(12), 0, theme:px(12))
		:align("center"):radius(theme:radius("sm")))
		:hover(sty():row():wrel(1.0):h(rowHeight):pad(0, theme:px(12), 0, theme:px(12))
		:align("center"):radius(theme:radius("sm")):bg(theme:color("hover")))
		:onClick(action)
		:children(text(label):style(theme:s():text(theme:type("sm")):fg(theme:color("text"))
		:ellipsis()))
	end
	entry("Play now", { type = "trackMenuPlay", id = track.id})
	entry("Add to playlist", { type = "trackMenuPlaylist", id = track.id})

	local panel = div()
	:style(sty():w(width):h(height):column():pad(theme:px(8)):gap(theme:px(2))
	:radius(theme:radius("md")):bg(theme:color("elevated"))
	:border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(12), theme:px(30), "#00000080"))
	:onClick({ type = "trackMenuKeep"})
	:children(rows)

	return div():style(sty():fill():offset(0, 0):z(120))
	:onClick({ type = "closeTrackMenu"})
	:children({ div():style(sty():w(width):h(height):offset(x, y)):children({ panel})})
end

--- The menu an album answers a right click with.
--- The playlist row's secondary click. Deleting removes the playlist and the hidden tag that
--- holds its hand-added tracks; the tag definitions themselves are untouched.
---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element?
function pages.playlistMenu(app, window)
	local menu = app.playlistMenu
	if menu == nil then return nil end
	local playlist = app.taxonomy:playlist(menu.id)
	if playlist == nil then return nil end

	local theme = app.theme
	local width = theme:px(196)
	local rowHeight = theme:px(34)
	local height = theme:px(8 * 2 + 34)
	local margin = theme:px(8)
	local x = math.max(margin, math.min(menu.x, window.width - width - margin))
	local y = math.max(margin, math.min(menu.y, window.height - height - margin))

	local row = div()
	:style(sty():row():wrel(1.0):h(rowHeight):pad(0, theme:px(12), 0, theme:px(12))
	:align("center"):radius(theme:radius("sm")))
	:hover(sty():row():wrel(1.0):h(rowHeight):pad(0, theme:px(12), 0, theme:px(12))
	:align("center"):radius(theme:radius("sm")):bg(theme:color("hover")))
	:onClick({ type = "deletePlaylist", id = playlist.id})
	:children(text("Delete playlist"):style(theme:s():text(theme:type("sm")):weight("semibold")
	:fg(theme:color("danger")):ellipsis()))

	local panel = div()
	:style(sty():w(width):h(height):column():pad(theme:px(8)):gap(theme:px(2))
	:radius(theme:radius("md")):bg(theme:color("elevated"))
	:border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(12), theme:px(30), "#00000080"))
	:onClick({ type = "playlistMenuKeep"})
	:children({ row})

	return div()
	:style(sty():fill():offset(0, 0):z(120))
	:onClick({ type = "closePlaylistMenu"})
	:children({
	div():style(sty():w(width):h(height):offset(x, y)):children({ panel}),
	})
end

---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element?
function pages.albumMenu(app, window)
	local menu = app.contextMenu
	local library = app.library
	if menu == nil or library == nil then return nil end
	local album = library:album(menu.id)
	if album == nil then return nil end

	local theme = app.theme
	local width = theme:px(218)
	local rowHeight = theme:px(34)
	local height = theme:px(8 * 2 + 34 * 4 + 2 * 3)
	local margin = theme:px(8)
	local x = math.max(margin, math.min(menu.x, window.width - width - margin))
	local y = math.max(margin, math.min(menu.y, window.height - height - margin))

	local rows = {}
	---@param label string
	---@param action any
	local function entry(label, action)
		rows[#rows + 1] = div()
		:style(sty():row():wrel(1.0):h(rowHeight):pad(0, theme:px(12), 0, theme:px(12))
		:align("center"):radius(theme:radius("sm")))
		:hover(sty():row():wrel(1.0):h(rowHeight):pad(0, theme:px(12), 0, theme:px(12))
		:align("center"):radius(theme:radius("sm")):bg(theme:color("hover")))
		:onClick(action)
		:children(text(label):style(theme:s():text(theme:type("sm")):fg(theme:color("text"))
		:ellipsis()))
	end

	entry("Play album", { type = "albumMenuPlay", id = album.id})
	entry("Add to playlist", { type = "playlistPicker", kind = "album", id = album.id})
	entry("Play next", { type = "albumMenuNext", id = album.id})
	entry("Add to queue", { type = "albumMenuQueue", id = album.id})

	local panel = div()
	:style(sty():w(width):h(height):column():pad(theme:px(8)):gap(theme:px(2))
	:radius(theme:radius("md")):bg(theme:color("elevated"))
	:border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(12), theme:px(30), "#00000080"))
	:onClick({ type = "albumMenuKeep"})
	:children(rows)

	return div()
	:style(sty():fill():offset(0, 0):z(120))
	:onClick({ type = "closeAlbumMenu"})
	:children({
	div():style(sty():w(width):h(height):offset(x, y)):children({ panel}),
	})
end

-- ────────────────────────────────────────────────────────────────
-- now playing menus
-- ────────────────────────────────────────────────────────────────

--- A label row in the two now-playing panels. They are deliberately taller than a context menu
--- row: these are the larger screens' utility menus rather than a right-click's short list.
---@param app beat.App
---@param label string
---@param action any
---@param width number
---@param height number
---@return wonderland.Element
local function nowPlayingEntry(app, label, action, width, height)
	local theme = app.theme
	return div()
	:style(sty():row():w(width):h(height):pad(0, theme:px(12), 0, theme:px(12))
	:align("center"):radius(theme:radius("sm")))
	:hover(sty():row():w(width):h(height):pad(0, theme:px(12), 0, theme:px(12))
	:align("center"):radius(theme:radius("sm")):bg(theme:color("hover")))
	:onClick(action)
	:children(text(label):style(theme:s():wrel(1.0):text(theme:type("sm"))
	:weight("medium"):fg(theme:color("text")):ellipsis()))
end

--- The queue is a panel instead of a permanent column, so the cover and controls keep the room
--- on every width. The phone gets the same sheet, just full width.
---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element?
function pages.queuePanel(app, window)
	if not app.queueOpen then return nil end
	local theme = app.theme
	local queue = app.player.queue
	local upcoming = queue and queue:upcoming(24) or {}
	local rowHeight = theme:px(48)
	local padding = theme:px(10)
	local headerHeight = theme:px(24)
	local gap = theme:px(4)
	local mobile = pages.mobile(app, window.width)
	local width = math.min(theme:px(340), window.width - (mobile and theme:px(24) or theme:px(32)))
	local most = math.max(1, math.min(#upcoming,
	math.floor((window.height - theme:px(220)) / rowHeight)))
	local shown = math.min(#upcoming, most)
	local more = #upcoming - shown
	local rowsHeight = shown * rowHeight + math.max(0, shown - 1) * gap
	local moreHeight = more > 0 and (theme:px(24) + gap) or 0
	local height = padding * 2 + headerHeight + gap + math.max(rowHeight, rowsHeight + moreHeight)

	local rows = {}
	rows[#rows + 1] = div():style(sty():row():wrel(1.0):h(headerHeight):align("center")
	:justify("space-between")):children({
	text("QUEUE"):style(theme:s():text(theme:type("xs")):weight("bold"):fg(theme:color("muted"))),
	text(util.count(#upcoming, "track")):style(theme:s():text(theme:type("xs"))
	:fg(theme:color("faint"))),
	})
	if shown == 0 then
		rows[#rows + 1] = div():style(sty():row():wrel(1.0):h(rowHeight):align("center")):children({
		text("Nothing queued yet"):style(theme:s():text(theme:type("sm")):fg(theme:color("muted"))),
		})
	else
		for at = 1, shown do
				local nextTrack = upcoming[at]
				---@cast nextTrack beat.Track
				rows[#rows + 1] = div()
				:style(sty():row():wrel(1.0):h(rowHeight):pad(0, theme:px(8), 0, theme:px(8))
				:gap(theme:px(8)):align("center"):radius(theme:radius("sm")))
				:hover(sty():row():wrel(1.0):h(rowHeight):pad(0, theme:px(8), 0, theme:px(8))
				:gap(theme:px(8)):align("center"):radius(theme:radius("sm"))
				:bg(theme:color("hover")))
				:onClick({ type = "jumpTrack", trackId = nextTrack.id})
				:children({
				div():style(sty():column():wrel(1.0)):children({
				text(nextTrack.title):style(theme:s():wrel(1.0):text(theme:type("sm"))
				:weight("semibold"):fg(theme:color("text")):ellipsis()),
				text(nextTrack.artist):style(theme:s():wrel(1.0):text(theme:type("xs"))
				:fg(theme:color("muted")):ellipsis()),
				}),
				text(util.clock(nextTrack.duration)):style(theme:s():text(theme:type("xs"))
				:fg(theme:color("faint"))),
				})
			end
		if more > 0 then
			rows[#rows + 1] = text("+" .. tostring(more) .. " more tracks"):style(
			theme:s():wrel(1.0):text(theme:type("xs")):fg(theme:color("faint")))
		end
	end

	local panel = div()
	:style(sty():w(width):h(height):column():pad(padding):gap(gap)
	:radius(theme:radius("md")):bg(theme:color("elevated"))
	:border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(12), theme:px(30), "#00000099"))
	:onClick({ type = "queueKeep"})
	:children(rows)
	local margin = theme:px(mobile and 12 or 24)
	local x = mobile and math.floor((window.width - width) / 2) or (window.width - width - margin)
	local y = window.height - height - margin

	return div()
	:style(sty():fill():offset(0, 0):z(128))
	:onClick({ type = "closeQueue"})
	:children({
	div():style(sty():w(width):h(height):offset(x, y)):children({ panel}),
	})
end

--- The three dots open the larger per-track menu: tagging, playlists, and the album and artist
--- pages that the compact controls no longer have room to grow another row for.
---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element?
function pages.nowPlayingMenu(app, window)
	if not app.moreOpen then return nil end
	local track = app:currentTrack()
	if track == nil then return nil end
	local theme = app.theme
	local album = app.library and app.library:album(track.albumId) or nil
	local entries = {
	{ "Tag track", { type = "openTagPicker", id = track.id}},
	{ "Add to playlist", { type = "nowPlayingPlaylist"}},
	}
	if album ~= nil then
		entries[#entries + 1] = { "Go to album",
		{ type = "navigate", page = { kind = "album", id = album.id}}}
		entries[#entries + 1] = { "Go to artist",
		{ type = "navigate", page = { kind = "artist", id = album.artistId}}}
	end
	entries[#entries + 1] = { "Open queue", { type = "openQueue"}}

	local mobile = pages.mobile(app, window.width)
	local width = math.min(theme:px(252), window.width - theme:px(24))
	local rowHeight = theme:px(40)
	local padding = theme:px(8)
	local gap = theme:px(2)
	local height = padding * 2 + #entries * rowHeight + math.max(0, #entries - 1) * gap
	local rows = {}
	for _, entry in ipairs(entries) do
			rows[#rows + 1] = nowPlayingEntry(app, entry[1] --[[@as string]], entry[2],
			width - padding * 2, rowHeight)
		end

	local panel = div()
	:style(sty():w(width):h(height):column():pad(padding):gap(gap)
	:radius(theme:radius("md")):bg(theme:color("elevated"))
	:border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(14), theme:px(36), "#00000099"))
	:onClick({ type = "moreKeep"})
	:children(rows)
	local margin = theme:px(mobile and 12 or 24)
	local x = mobile and math.floor((window.width - width) / 2) or (window.width - width - margin)
	local y = window.height - height - margin

	return div()
	:style(sty():fill():offset(0, 0):z(129))
	:onClick({ type = "closeMore"})
	:children({
	div():style(sty():w(width):h(height):offset(x, y)):children({ panel}),
	})
end

-- ────────────────────────────────────────────────────────────────
-- equalizer
-- ────────────────────────────────────────────────────────────────

---@param app beat.App
---@param preset beat.EqualizerPreset
---@param width number
---@param height number
---@return wonderland.Element
local function equalizerChip(app, preset, width, height)
	local theme = app.theme
	local selected = app.settings.equalizerPreset == preset.id
	local textColour = selected and theme.accentInk or theme:color("muted")
	local resting = selected and theme:color("accent") or theme:color("surface")
	local hover = selected and theme:color("accent", 0.86) or theme:color("hover")
	local chip = div()
	:style(sty():row():w(width):h(height):align("center"):justify("center")
	:radius(theme:radius("full")):bg(resting))
	:hover(sty():row():w(width):h(height):align("center"):justify("center")
	:radius(theme:radius("full")):bg(hover))
	:onClick({ type = "equalizerPreset", id = preset.id})
	:children(text(preset.name):style(theme:s():text(theme:type("xs")):weight("semibold")
	:fg(textColour):ellipsis()))
	if preset.custom then
		chip:onDoubleClick({ type = "editEqualizerPreset", name = preset.id})
	end
	return chip
end

--- The equalizer panel: preset shapes above five bands, each band a slider and a signed gain. It
--- is deliberately a panel rather than a permanent row of faders: the controls are a deliberate
--- adjustment, not something that should compete with the transport every frame.
---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element?
function pages.equalizerPanel(app, window)
	if not app.equalizerOpen then return nil end
	local theme = app.theme
	local compact = window.height < theme:px(520)
	local width = math.min(theme:px(460), window.width - theme:px(24))
	local padding = compact and theme:px(10) or theme:px(18)
	local gap = compact and theme:px(6) or theme:px(8)
	local content = width - padding * 2
	local chipWidth = compact and theme:px(72) or theme:px(78)
	local chipHeight = compact and theme:px(22) or theme:px(24)
	local presets = app:equalizerPresets()
	local columns = math.max(1, math.floor((content + gap) / (chipWidth + gap)))
	local presetRows = math.ceil(#presets / columns)
	local presetHeight = presetRows * chipHeight + (presetRows - 1) * gap
	local rowHeight = compact and theme:px(26) or theme:px(30)
	local bandGap = theme:px(3)
	local bandsHeight = #core.equalizer.frequencies * rowHeight
	+(#core.equalizer.frequencies - 1) * bandGap
	local headerHeight = compact and theme:px(22) or theme:px(24)
	local height = padding * 2 + headerHeight + gap + presetHeight + gap + bandsHeight
	local panels = {}

	local header = div():style(sty():row():wrel(1.0):h(headerHeight):align("center")
	:justify("space-between")):children({
	text("Equalizer"):style(theme:s():text(theme:type("md")):weight("bold")
	:fg(theme:color("text"))),
	div():style(sty():row():w(theme:px(24) * 2 + theme:px(4)):h(headerHeight)
	:gap(theme:px(4)):align("center")):children({
	render.iconButton(app, "add", theme:px(24), { type = "newEqualizerPreset"}),
	render.iconButton(app, "close", theme:px(24), { type = "closeEqualizer"}),
	}),
	})
	panels[#panels + 1] = header

	for row = 1, presetRows do
			local children = {}
			for column = 1, columns do
					local at = (row - 1) * columns + column
					local preset = presets[at] --[[@as beat.EqualizerPreset?]]
					if preset ~= nil then
						children[#children + 1] = equalizerChip(app,
						preset --[[@as beat.EqualizerPreset]], chipWidth, chipHeight)
					end
				end
			panels[#panels + 1] = div():style(sty():row():wrel(1.0):h(chipHeight):gap(gap)
			:align("center")):children(children)
		end

	local labelWidth = theme:px(60)
	local valueWidth = theme:px(44)
	local sliderWidth = content - labelWidth - valueWidth - gap * 2
	for at = 1, #core.equalizer.frequencies do
			local band = at
			local gain = app.settings.equalizerGains[at] or 0
			local shown = math.floor(gain + 0.5)
			local value = shown == 0 and "0 dB" or string.format("%+d dB", shown)
			panels[#panels + 1] = div():style(sty():row():wrel(1.0):h(rowHeight):gap(gap)
			:align("center")):children({
			text(core.equalizer.labels[at]):style(theme:s():w(labelWidth):text(theme:type("xs"))
			:fg(theme:color("muted"))),
			render.slider(app, {
			width = sliderWidth,
			value = gain,
			min = core.equalizer.minimum,
			max = core.equalizer.maximum,
			origin = 0.5,
			onchange = function(value_) return { type = "equalizerGain", band = band, value = value_} end,
			trackColour = theme:color("text", 0.12),
			fillColour = theme:color("accent"),
			thumbColour = theme:color("text"),
			thumbSize = theme:px(12),
			}),
			text(value):style(theme:s():w(valueWidth):text(theme:type("xs"))
			:fg(theme:color("text"))),
			})
		end

	local panel = div()
	:style(sty():w(width):h(height):column():pad(padding):gap(gap)
	:radius(theme:radius("md")):bg(theme:color("elevated"))
	:border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(14), theme:px(36), "#00000099"))
	:onClick({ type = "equalizerKeep"})
	:children(panels)

	return div()
	:style(sty():size(window.width, window.height):offset(0, 0):z(130)
	:column():align("center"):justify("center")
	:bg(theme:color("overlay"))):onClick({ type = "closeEqualizer"})
	:children({ panel})
end

---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element?
function pages.equalizerRenameDialog(app, window)
	local name = app.equalizerEdit
	if name == nil then return nil end
	local theme = app.theme
	local width = math.min(theme:px(340), window.width - theme:px(32))
	local padding = theme:px(16)
	local height = theme:px(220)
	local panel = div()
	:style(sty():w(width):h(height):column():pad(padding):gap(theme:px(10))
	:radius(theme:radius("md")):bg(theme:color("elevated"))
	:border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(14), theme:px(36), "#00000099"))
	:onClick({ type = "equalizerEditKeep"})
	:children({
	text("Rename preset"):style(theme:s():text(theme:type("lg")):weight("bold")
	:fg(theme:color("text"))),
	dialogField(app, "equalizerPresetName", app.equalizerEditDraft, "Preset name",
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
	:bg(theme:color("overlay"))):onClick({ type = "cancelEqualizerPresetRename"})
	:children({ panel})
end

-- ────────────────────────────────────────────────────────────────
-- A page slide has the same handful of positions every time. They are made once per scale and
-- picked from, rather than made from the frame's exact progress: a style is interned by its
-- values, so asking for one per frame is asking the arena to grow with every transition.
---@type table<number, { forward: wonderland.StyleBuilder[], back: wonderland.StyleBuilder[] }>
local transitionCache = {}
local TRANSITION_STEPS = 16

---@param theme beat.ui.Theme
---@return { forward: wonderland.StyleBuilder[], back: wonderland.StyleBuilder[] }
local function transitionStyles(theme)
	local cached = transitionCache[theme.scale]
	if cached ~= nil then return cached end

	local forward, back = {}, {}
	for at = 0, TRANSITION_STEPS do
			local t = at / TRANSITION_STEPS
			local distance = (1 - t) * theme:px(28)
			local dim = 0.88 + 0.12 * t
			forward[at] = sty():fill():column():offset(distance, 0):bright(dim)
			back[at] = sty():fill():column():offset(-distance, 0):bright(dim)
		end

	cached = { forward = forward, back = back}
	transitionCache[theme.scale] = cached
	return cached
end

-- root
-- ────────────────────────────────────────────────────────────────

--- The screens that sit over a page. They are appended to the normal root and to expanded now
--- playing alike, so tagging or adding to a playlist works in either view.
---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element[]
local function pageOverlays(app, window)
	local overlays = {}
	local function add(value)
		if value ~= nil then overlays[#overlays + 1] = value end
	end
	add(pages.tagPicker(app, window))
	add(pages.tagDialog(app, window))
	add(pages.tagDeleteDialog(app, window))
	add(pages.playlistDialog(app, window))
	add(pages.playlistPicker(app, window))
	add(pages.playlistAdder(app, window))
	add(pages.trackMenu(app, window))
	add(pages.albumMenu(app, window))
	add(pages.playlistMenu(app, window))
	add(pages.queuePanel(app, window))
	add(pages.nowPlayingMenu(app, window))
	add(pages.equalizerPanel(app, window))
	add(pages.equalizerRenameDialog(app, window))
	return overlays
end

---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element
function pages.view(app, window)
	local theme = app.theme
	local assets = app.assets
	if assets ~= nil then app.covers:use(assets) end
	app.covers:beginFrame()

	local width = window.width
	local height = window.height
	local mobile = pages.mobile(app, width)
	local bar = app:currentTrack() ~= nil and theme:px(mobile and 64 or 88) or 0
	local page = app.page
	local content

	-- Expanded now playing is the screen, not a panel over one: the page, the sidebar and the
	-- bar are not built at all, so nothing underneath can be clicked through and nothing around
	-- the edges is left showing.
	if app.expanded and app:currentTrack() ~= nil then
		local expanded = pages.expanded(app, window)
		if expanded ~= nil then
			-- The screen itself is padded, but overlays are placed in window coordinates. A bare
			-- wrapper keeps their fill and offsets measured from the window rather than from the
			-- screen's inset.
			local frame = div():style(sty():fill()):children({ expanded})
			for _, overlay in ipairs(pageOverlays(app, window)) do frame:children({ overlay}) end
			app.covers:sweep()
			return frame
		end
	end

	if app:needsFolder() then
		return div()
		:style(sty():fill():column():bg(theme:color("bg")):fg(theme:color("text"))
		:font(theme.fontFamily))
		:children({
		div():style(sty():fill():column():align("center"):justify("center")):children({
		div():style(sty():w(math.min(theme:px(620), width - pages.pad(app, width) * 2))
		:h(theme:px(600)):column():gap(theme:space(18))):children({
		div():style(sty():row():h(theme:px(28)):gap(theme:px(10)):align("center")):children({
		ui.icons.element("logo", theme:px(28), theme:color("accent")),
		text("beat"):style(theme:s():text(theme:type("xxl")):weight("bold")
		:fg(theme:color("text"))),
		}),
		foldersPage(app, window),
		}),
		}),
		})
	end

	if page.kind == "home" then
		content = home(app, window)
	elseif page.kind == "library" then
		content = libraryPage(app, window)
	elseif page.kind == "search" then
		content = searchPage(app, window)
	elseif page.kind == "searchAll" then
		content = searchAllPage(app, window, page.category)
	elseif page.kind == "album" then
		local album
		if app.library ~= nil then album = app.library:album(page.id) end
		if album ~= nil then
			---@cast album beat.Album
			content = albumPage(app, window, album)
		else
			content = render.empty(app, "Album not found", "The scan no longer has it.", "Library",
			{ type = "navigate", page = { kind = "library"}})
		end
	elseif page.kind == "artist" then
		local artist
		if app.library ~= nil then artist = app.library:artist(page.id) end
		if artist ~= nil then
			---@cast artist beat.Artist
			content = artistPage(app, window, artist)
		else
			content = render.empty(app, "Artist not found", "The scan no longer has them.", "Library",
			{ type = "navigate", page = { kind = "library"}})
		end
	elseif page.kind == "playlists" then
		content = playlistsPage(app, window)
	elseif page.kind == "playlist" then
		local playlist = app.taxonomy:playlist(page.id --[[@as number]])
		if playlist ~= nil then
			---@cast playlist beat.Playlist
			content = playlistPage(app, window, playlist)
		else
			content = render.empty(app, "Playlist not found", nil, "Playlists",
			{ type = "navigate", page = { kind = "playlists"}})
		end
	elseif page.kind == "settings" then
		content = settingsPage(app, window)
	elseif page.kind == "folders" then
		content = foldersPage(app, window)
	else
		content = home(app, window)
	end

	local bottomHeight = pages.bottomHeight(app, width)
	local pageHeight = height - bottomHeight
	local topbarHeight = pages.topbarHeight(app, width)
	local bodyHeight = pageHeight - topbarHeight
	local scrollKey = app:pageKey()
	local scroll = app:scrollOffset(scrollKey)

	local transition = app.transition
	local transitionStyle
	if transition ~= nil and not app.motion.reduce then
		local t = ui.motion.progress(transition.start, 0.28, wonderland.time.now(), ui.motion.ease.outCubic)
		local transitionSet = transitionStyles(theme)
		local direction = (transition.direction or 1) < 0 and transitionSet.back or transitionSet.forward
		transitionStyle = direction[math.floor(t * 16 + 0.5)]
	end

	local pageBody = div()
	:style(sty():column():wrel(1.0):h(bodyHeight):pad(theme:space(20), pages.pad(app, width), 0,
	pages.pad(app, width)):gap(theme:space(18)):bar(theme:px(8), theme:px(40), theme:color("faint")))
	:scroll(scroll)
	:onScroll(function(by, to) return { type = "scroll", by = by, to = to} end)
	:children({ content})

	-- The page is moved by a wrapper whose styles are made once per scale, not by a style that
	-- names the frame's exact position: a style is interned by its values, and interning a new
	-- one every frame is what made repeated transitions slower and slower.
	local moving = transitionStyle == nil and pageBody
	or div():style(transitionStyle):children({ pageBody})

	-- Clipped so a page arriving from the side cannot draw over the sidebar during its travel.
	local pageClip = div():style(sty():column():wrel(1.0):h(bodyHeight)):scroll(0)
	:onScroll(function(by, to) return { type = "scroll", by = by, to = to} end)
	:children({ moving})

	local rightWidth = width - pages.sidebarWidth(app, width)
	local main = div():style(sty():column():w(rightWidth):h(pageHeight))
	if not mobile then
		main:onMouseMove(function()
			if app.hoverPlaylist ~= nil then return { type = "hoverPlaylist", id = nil} end
			return nil
		end)
	end
	main:children({
	topbar(app, width),
	div():style(sty():column():wrel(1.0):h(bodyHeight)):children({ pageClip}),
	})

	local shellChildren = { main}
	if not mobile then table.insert(shellChildren, 1, sidebar(app, width, pageHeight)) end
	local shell = div():style(sty():row():wrel(1.0):h(pageHeight)):children(shellChildren)

	local rootChildren = { shell}
	if mobile then
		if bar > 0 then rootChildren[#rootChildren + 1] = mobileNowPlaying(app, width) end
		rootChildren[#rootChildren + 1] = mobileNav(app, width)
	elseif bar > 0 then
		rootChildren[#rootChildren + 1] = nowPlaying(app, width)
	end
	local scanIsland = pages.scanIsland(app, width)
	if scanIsland ~= nil then rootChildren[#rootChildren + 1] = scanIsland end
	local scanSummary = pages.scanSummary(app, width)
	if scanSummary ~= nil then rootChildren[#rootChildren + 1] = scanSummary end
	local sortMenu = pages.sortMenu(app, window)
	if sortMenu ~= nil then rootChildren[#rootChildren + 1] = sortMenu end
	if not mobile then
		local tooltip = pages.playlistTooltip(app, width, height)
		if tooltip ~= nil then rootChildren[#rootChildren + 1] = tooltip end
	end

	local root = div()
	:style(sty():fill():column():bg(theme:color("bg")):fg(theme:color("text"))
	:font(theme.fontFamily))
	:children(rootChildren)

	local expanded = pages.expanded(app, window)
	if expanded ~= nil then root:children(expanded) end

	local toasts = pages.toasts(app, window)
	if toasts ~= nil then root:children(toasts) end

	local accentPicker = pages.accentPicker(app, window)
	if accentPicker ~= nil then root:children(accentPicker) end

	for _, overlay in ipairs(pageOverlays(app, window)) do root:children({ overlay}) end

	-- Everything this view asked for is kept; covers a changing page no longer asks for are
	-- given back before the next frame, so a scan cannot accumulate one texture per album.
	app.covers:sweep()

	return root
end

return pages
