-- The playlists page: the lists the library makes by itself, the ones the listener made, and the
-- tags that make the automatic ones. A tag's name is edited in place here, so the draft and the
-- one being edited belong to this page.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local metrics = require("beat.app.components.helpers.metrics")
local measure = require("beat.app.components.helpers.measure")
local Smart = require("beat.app.services.collections.smart")
local tile = require("beat.app.components.playlists.tile")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.PlaylistsState
---@field tagEditId number? # The tag whose name is being edited in place
---@field tagEditDraft string
---@field hoverTagId number?

---@type beat.PageSurface
local playlists = {}

function playlists.new()
	---@type beat.PlaylistsState
	return { tagEditId = nil, tagEditDraft = "", hoverTagId = nil }
end

--- Leaving puts an edited tag's pill back: the edit is about this page while it is looked at.
---@param page beat.PageInstance<beat.PlaylistsState>
function playlists.leave(_, page)
	local state = page.state
	state.tagEditId = nil
	state.hoverTagId = nil
end

---@param app beat.App
---@param page beat.PageInstance<beat.PlaylistsState>
---@param message beat.Message
function playlists.update(app, page, message)
	local state = page.state
	if message.type == "editTag" then
		local tag = app.services.collections.taxonomy.tagById[tonumber(message.id)]
		if tag ~= nil and not tag.hidden then
			state.tagEditId = tag.id
			state.tagEditDraft = tag.name
			app:focusField("tagName", #tag.name)
			app:refresh()
		end
		return true
	elseif message.type == "tagEditDraft" then
		state.tagEditDraft = message.value or ""
		app:refresh()
		return true
	elseif message.type == "cancelTagEdit" then
		state.tagEditId = nil
		state.tagEditDraft = ""
		app:focusField(nil)
		app:refresh()
		return true
	elseif message.type == "renameTag" then
		local tag = app.services.collections.taxonomy:renameTag(state.tagEditId --[[@as number]],  state.tagEditDraft )
		if tag == nil then
			app.services.toasts:show("Choose a tag name that is not already used", "error")
		else
			app.services.collections:save()
			state.tagEditId = nil
			state.tagEditDraft = ""
			app:focusField(nil)
			app.services.toasts:show("Tag renamed · " .. tag.name)
		end
		app:refresh()
		return true
	elseif message.type == "hoverTag" then
		if state.hoverTagId ~= message.id then
			state.hoverTagId = message.id
			app:refresh()
		end
		return true
	elseif message.type == "deleteTag" then
		local id = tonumber(message.id)
		local tag = id ~= nil and app.services.collections.taxonomy.tagById[id] or nil
		if tag ~= nil then
			-- A tag a track uses asks first; an empty one only removes its own list.
			if tag.count > 0 then
				app:open("tag_delete", { id = tag.id })
			else
				-- The row's hover and the name field if this tag was being edited belong to this
				-- page, so they go with the tag here; the search service drops it from its filter
				-- when collections announce the change.
				if state.tagEditId == tag.id then
					state.tagEditId = nil
					state.tagEditDraft = ""
					app:focusField(nil)
				end
				if state.hoverTagId == tag.id then state.hoverTagId = nil end
				app.services.collections:deleteTag(tag.id)
				app:refresh()
			end
		end
		return true
	end
	return false
end

---@param app beat.App
---@param page beat.PageInstance<beat.PlaylistsState>
---@param window wonderland.RenderWindow
---@return wonderland.Element
function playlists.view(app, page, window)
	local state = page.state
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local mobile = metrics.mobile(app, window.width)
	local taxonomy = app.services.collections.taxonomy
	local content = metrics.contentWidth(app, window.width)
	local tags = taxonomy:visibleTags()

	-- No create buttons up here: a playlist is made from the + tile that opens its own grid, and a
	-- tag from the + pill at the end of the tags, so each is made where it will appear.
	local titleHeight = math.floor(theme:type("xxl") * 1.25)
	local headerHeight = titleHeight
	local header = text("Playlists")
		:style(theme:s():wrel(1.0):h(titleHeight):text(theme:type("xxl")):weight("bold"):fg(theme:color("text")):ellipsis())

	-- Two across on a phone and at least four on a desktop, which is the ladder the shelves use
	-- widened to the promise this page makes: the smart lists read as a row, not a column.
	local gap = theme:space(16)
	local columns = metrics.gridColumns(app, content)
	columns = mobile and math.min(2, columns) or math.max(4, columns)
	local tileWidth = math.max(theme:px(120), math.floor((content - gap * (columns - 1)) / columns))
	local tileHeight = tile.height(app, { width = tileWidth, mobile = mobile })
	local rowStyle = sty():row():wrel(1.0):h(tileHeight):gap(gap)

	---@param tiles wonderland.Element[]
	---@return wonderland.Element[]
	local function grid(tiles)
		local rows = {}
		local row = {}
		for at, element in ipairs(tiles) do
			row[#row + 1] = element
			if #row == columns or at == #tiles then
				rows[#rows + 1] = div():style(rowStyle):children(row)
				row = {}
			end
		end
		return rows
	end

	---@param count number
	---@return number
	local function gridHeight(count)
		if count == 0 then return 0 end
		local rows = math.ceil(count / columns)
		return rows * tileHeight + (rows - 1) * gap
	end

	---@param playlist beat.Playlist
	---@param list beat.Track[]
	---@param builtin boolean
	---@return wonderland.Element
	local function playlistTile(playlist, list, builtin)
		local menu
		if not builtin then
			menu = |_, _, _, _, _, windowX, windowY| -> {
				type = "open",
				overlay = "menu",
				menu = "playlist",
				id = playlist.id,
				x = windowX,
				y = windowY
			}
		end
		return tile.view(
			app,
			{
				width = tileWidth,
				playlist = playlist,
				tracks = list,
				mobile = mobile,
				ui = ctx,
				onOpen = { type = "navigate", page = { kind = "playlist", id = playlist.id } },
				onMenu = menu
			}
		)
	end

	local smartTiles = {}
	for _, playlist in ipairs(Smart.all()) do
		smartTiles[#smartTiles + 1] = playlistTile(playlist, app.services.collections:playlistTracks(playlist), true)
	end

	-- The automatic playlist a tag carries is shown as the tag itself below; this grid is the
	-- lists the listener chose to make.
	local own = {}
	for _, playlist in ipairs(taxonomy.playlists) do
		if playlist.autoTagId == nil then own[#own + 1] = playlist end
	end
	local ownTiles = {
		tile.newPlaylist(
			app,
			{
				width = tileWidth,
				mobile = mobile,
				ui = ctx,
				onCreate = { type = "open", overlay = "playlist_dialog", smart = false }
			}
		)
	}
	for _, playlist in ipairs(own) do
		ownTiles[#ownTiles + 1] = playlistTile(playlist, app.services.collections:playlistTracks(playlist), false)
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
	local pillHeight = theme:px(mobile and 44 or 34)
	local closeWidth = theme:px(mobile and 44 or 22)
	local editCheck = mobile and closeWidth or theme:px(24)
	local editCancel = mobile and closeWidth or theme:px(22)
	local nameSize = (theme:type(mobile ? "sm" : "base"))
	local emptyTagHeight = theme:px(20)

	local function flushTagLine()
		if #tagLine == 0 then return end
		tagRows[#tagRows + 1] = div():style(sty():row():wrel(1.0):h(pillHeight):gap(pillGap)):children(tagLine)
		tagLine = {}
		lineWidth = 0
	end

	for _, tag in ipairs(tags) do
		local countText = tostring(tag.count)
		local countStyle = theme:s():text(theme:type("xs"))
		local countFallback = math.floor(#countText * theme:type("xs") * 0.7)
		local countWidth = math.max(
			theme:px(12),
			math.ceil(math.max(measure.width(app, countText, countStyle) or 0, countFallback)) + 1
		)
		local nameStyle = theme:s():text(nameSize):weight("semibold")
		local nameFallback = measure.estimate(tag.name, nameSize, 0.54)
		local nameWidth = math.max(
			theme:px(16),
			math.ceil(math.max(measure.width(app, tag.name, nameStyle) or 0, nameFallback)) + 1
		)
		-- The row break is manual because Wonderland has no wrap container, but each pill's
		-- width comes from the same measured runs the text is drawn with.
		local estimatedWidth = pillPadLeft + pillPadRight + countWidth + nameWidth + closeWidth + gaps
		estimatedWidth = math.min(content, math.max(theme:px(64), estimatedWidth))
		nameWidth = math.max(theme:px(16), estimatedWidth - pillPadLeft - pillPadRight - countWidth - closeWidth - gaps)

		local editing = state.tagEditId == tag.id
		local pill
		local usedWidth = estimatedWidth
		if editing then
			local editWidth = math.min(content, math.max(estimatedWidth, theme:px(mobile ? 240 : 190)))
			usedWidth = editWidth
			local fieldWidth = math.max(
				theme:px(80),
				editWidth - theme:px(20) - editCheck - editCancel - theme:px(8)
			)
			local nameField = ui.field(
				ctx,
				{
					name = "tagName",
					value = state.tagEditDraft,
					placeholder = tag.name,
					oninput = |value| -> { type = "tagEditDraft", value = value },
					onsubmit = || -> { type = "renameTag" },
					width = fieldWidth
				}
			)
			pill = div()
				:style(
					sty()
						:row():w(editWidth):h(pillHeight):gap(theme:px(4)):pad(0, theme:px(8), 0, theme:px(8)):align("center")
						:radius(theme:radius("full")):bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
				)
				:children(
					{
						nameField,
						ui.iconButton(ctx, { name = "check", size = editCheck, onClick = { type = "renameTag" } }),
						ui.iconButton(ctx, { name = "close", size = editCancel, onClick = { type = "cancelTagEdit" } })
					}
				)
		else
			pill = div()
				:style(
					sty()
						:row():w(estimatedWidth):h(pillHeight):gap(theme:px(6)):pad(0, pillPadRight, 0, pillPadLeft):align("center")
						:radius(theme:radius("full")):bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
				)
				:hover(
					sty()
						:row():w(estimatedWidth):h(pillHeight):gap(theme:px(6)):pad(0, pillPadRight, 0, pillPadLeft):align("center")
						:radius(theme:radius("full")):bg(theme:color("hover")):border(theme:px(1), theme:color("border"))
				):onMouseMove(|| -> { type = "hoverTag", id = tag.id })
				:children(
					{
						text(countText):style(countStyle:w(countWidth):fg(theme:color("faint")):ellipsis()),
						text(tag.name)
							:style(nameStyle:w(nameWidth):fg(theme:color("text")):ellipsis()):onClick({ type = "editTag", id = tag.id }),
						div()
							:style(sty():size(closeWidth, pillHeight):align("center"):justify("center"))
							:onClick({ type = "deleteTag", id = tag.id })
							:children(text("×"):style(theme:s():text(theme:type("lg")):weight("semibold"):fg(theme:color("muted"))))
					}
				)
		end

		if lineWidth > 0 and lineWidth + pillGap + usedWidth > content then flushTagLine() end
		tagLine[#tagLine + 1] = pill
		lineWidth = lineWidth + (lineWidth > 0 and pillGap or 0) + usedWidth
	end

	-- The last pill makes a new tag: accent-edged like the New playlist tile, so the two ways to
	-- make something look alike, and placed where the tag it makes will appear.
	local newLabel = "New tag"
	local newLabelStyle = theme:s():text(nameSize):weight("semibold")
	local newLabelWidth = math.ceil(math.max(measure.width(app, newLabel, newLabelStyle) or 0, measure.estimate(newLabel, nameSize, 0.54))) + 1
	local newIconSize = theme:px(mobile and 18 or 15)
	local newWidth = pillPadLeft + newIconSize + theme:px(6) + newLabelWidth + theme:px(14)
	local function newPillStyle(alpha)
		return sty()
			:row():w(newWidth):h(pillHeight):gap(theme:px(6)):pad(0, theme:px(14), 0, pillPadLeft):align("center")
			:radius(theme:radius("full")):bg(theme:color("accent", alpha)):border(theme:px(1), theme:color("accent", 0.45))
	end
	local newPill = div()
		:style(newPillStyle(0.06)):hover(newPillStyle(0.14))
		:onClick({ type = "open", overlay = "tag_dialog" })
		:children(
			{
				ui.icon(ctx, { name = "add", size = newIconSize, colour = theme:color("accent") }),
				text(newLabel):style(newLabelStyle:w(newLabelWidth):fg(theme:color("accent")))
			}
		)
	if lineWidth > 0 and lineWidth + pillGap + newWidth > content then flushTagLine() end
	tagLine[#tagLine + 1] = newPill
	lineWidth = lineWidth + (lineWidth > 0 and pillGap or 0) + newWidth
	flushTagLine()

	local tagHeight = #tagRows * pillHeight + math.max(0, #tagRows - 1) * pillGap
	if #tags == 0 then
		-- With no tags yet the pill alone does not say what a tag is for.
		tagRows[#tagRows + 1] = text("A tag is also a smart playlist.")
			:style(theme:s():wrel(1.0):h(emptyTagHeight):text(theme:type("sm")):fg(theme:color("muted")))
		tagHeight = tagHeight + pillGap + emptyTagHeight
	end
	local sectionHeight = theme:px(24)
	local sectionGap = theme:space(18)
	local smartHeight = gridHeight(#smartTiles)
	local ownHeight = gridHeight(#ownTiles)

	local children = {}
	local height = 0
	local function add(element, elementHeight)
		if #children > 0 then height = height + sectionGap end
		children[#children + 1] = element
		height = height + elementHeight
	end

	add(header, headerHeight)
	add(ui.section(ctx, { title = "Smart playlists" }), sectionHeight)
	add(
		div():style(sty():column():wrel(1.0):h(smartHeight):gap(gap)):children(grid(smartTiles)),
		smartHeight
	)
	add(ui.section(ctx, { title = "Your playlists" }), sectionHeight)
	add(div():style(sty():column():wrel(1.0):h(ownHeight):gap(gap)):children(grid(ownTiles)), ownHeight)
	add(ui.section(ctx, { title = "Tags" }), sectionHeight)
	add(div():style(sty():column():wrel(1.0):h(tagHeight):gap(pillGap)):children(tagRows), tagHeight)

	app.services.scroll:setLimit(app:pageKey(), metrics.pageScrollLimit(app, window, height))

	return div():style(sty():column():wrel(1.0):h(height):gap(sectionGap)):children(children)
end

return playlists
