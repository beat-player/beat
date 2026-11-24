-- The playlists page: the lists the library makes by itself, the ones the listener made, and the
-- tags that make the automatic ones. A tag's name is edited in place here, so the draft and the
-- one being edited belong to this page.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local metrics = require("beat.app.components.helpers.metrics")
local measure = require("beat.app.components.helpers.measure")
local Smart = require("beat.app.services.collections.smart")
local tile = require("beat.app.components.playlists.tile")
local styles = require("beat.app.components.helpers.styles")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.PlaylistsState
---@field tagEditId number? # The tag whose name is being edited in place
---@field tagEditDraft string
---@field hoverTagId number?

-- The messages and hover handler a tag's pill sends, one per tag rather than one per pill per
-- frame: the pill is built again whenever the page is scrolled.
-- The tag name field's handlers, made once rather than on every frame the page is open.
---@param value string
---@return table
local function tagEditTyped(value)
	return { type = "tagEditDraft", value = value }
end

---@return table
local function submitRename()
	return { type = "renameTag" }
end

---@class beat.pages.PlaylistsTagActions
---@field edit table
---@field delete table
---@field hover fun(): table

---@type table<beat.Tag, beat.pages.PlaylistsTagActions>
local tagActions = setmetatable({}, { __mode = "k" })

--- The messages one tag's pill sends, made the first time the tag is shown: the hover handler
--- names the tag, so it is a function of its own, and making it apart from the lookup keeps that
--- closure off the frames that only read the record.
---@param tag beat.Tag
---@return beat.pages.PlaylistsTagActions
local function buildTagActions(tag)
	local id = tag.id
	return {
		edit = { type = "editTag", id = id },
		delete = { type = "deleteTag", id = id },
		hover = || -> { type = "hoverTag", id = id }
	}
end

---@param tag beat.Tag
---@return beat.pages.PlaylistsTagActions
local function actionsFor(tag)
	local found = tagActions[tag]
	if found == nil then
		found = buildTagActions(tag)
		tagActions[tag] = found
	end
	return found
end

--- The boxes and measured widths of one tag's pill, kept with the tag, the words and the room it
--- was measured for: the page is built again on every scroll step.
---@class beat.pages.PlaylistsPillStyles
---@field theme beat.Theme
---@field mix number
---@field mobile boolean
---@field content number
---@field nameSize number
---@field countText string
---@field name string
---@field pillHeight number
---@field estimatedWidth number
---@field pill wonderland.StyleBuilder
---@field hover wonderland.StyleBuilder
---@field countStyle wonderland.StyleBuilder
---@field nameStyle wonderland.StyleBuilder
---@field editPill wonderland.StyleBuilder

---@type table<beat.Tag, beat.pages.PlaylistsPillStyles>
local tagStyles = setmetatable({}, { __mode = "k" })

--- A section's column box, kept for the height and gap it was made for.
---@param theme beat.Theme
---@param height number
---@param gap number
local function columnStyle(theme, height, gap)
	local kept = styles.of(theme, "playlistsColumn", height) --[[@as { style: wonderland.StyleBuilder?, gap: number? }]]
	if kept.style == nil or kept.gap ~= gap then
		kept.gap = gap
		kept.style = sty():column():wrel(1.0):h(height):gap(gap)
	end
	return assert(kept.style)
end

--- The parts every pill shares, kept per theme and the numbers they were built from. A new-tag
--- pill's box depends on its own width, so that is part of the key too.
---@param theme beat.Theme
---@param closeWidth number
---@param pillHeight number
---@param newWidth number
---@return table<string, wonderland.StyleBuilder>
local function pillParts(theme, closeWidth, pillHeight, newWidth)
	local kept = styles.of(theme, "playlistsPills", closeWidth) --[[@as table<number, table>]]
	local byHeight = kept[pillHeight]
	if byHeight == nil then
		byHeight = {}
		kept[pillHeight] = byHeight
	end
	local parts = byHeight[newWidth]
	if parts == nil then
		parts = {
			closeBox = sty():size(closeWidth, pillHeight):align("center"):justify("center"),
			closeText = theme:s():text(theme:type("lg")):weight("semibold"):fg(theme:color("muted")),
			newPill = sty()
				:row():w(newWidth):h(pillHeight):gap(theme:px(6)):pad(0, theme:px(14), 0, theme:px(10)):align("center")
				:radius(theme:radius("full")):bg(theme:color("accent", 0.06)):border(theme:px(1), theme:color("accent", 0.45)),
			newPillHover = sty()
				:row():w(newWidth):h(pillHeight):gap(theme:px(6)):pad(0, theme:px(14), 0, theme:px(10)):align("center")
				:radius(theme:radius("full")):bg(theme:color("accent", 0.14)):border(theme:px(1), theme:color("accent", 0.45))
		}
		byHeight[newWidth] = parts
	end
	return parts
end

--- The props a playlist's tile is built from, kept per playlist: only the window and the room the
--- tile has change between frames.
---@type table<beat.Playlist, beat.components.playlists.TileProps>
local tileProps = setmetatable({}, { __mode = "k" })

--- The rows a shelf of tiles comes out as, at the columns and row box the page works out.
---@param tiles wonderland.Element[]
---@param columns number
---@param rowStyle wonderland.StyleBuilder
---@return wonderland.Element[]
local function gridRows(tiles, columns, rowStyle)
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
---@param columns number
---@param tileHeight number
---@param gap number
---@return number
local function gridHeightFor(count, columns, tileHeight, gap)
	if count == 0 then return 0 end
	local rows = math.ceil(count / columns)
	return rows * tileHeight + (rows - 1) * gap
end

--- One playlist's tile, with the props it keeps between frames written again for this one.
---@param app beat.App
---@param playlist beat.Playlist
---@param list beat.Track[]
---@param builtin boolean
---@param tileWidth number
---@param mobile boolean
---@param ctx beat.ui.Context
---@return wonderland.Element
local function playlistTile(app, playlist, list, builtin, tileWidth, mobile, ctx)
	local props = tileProps[playlist]
	if props == nil then
		local id = playlist.id
		---@type beat.components.playlists.TileProps
		props = {
			playlist = playlist,
			onOpen = { type = "navigate", page = { kind = "playlist", id = id } },
			-- The menu opens where the pointer is, which is where a right-click landed.
			onMenu = not builtin and { type = "open", overlay = "menu", menu = "playlist", id = id } or nil
		}
		tileProps[playlist] = props
	end
	props.width = tileWidth
	props.tracks = list
	props.mobile = mobile
	props.ui = ctx
	return tile.view(app, props --[[@as beat.components.playlists.TileProps]])
end

--- A row of tag pills, put into `tagRows` when it is full. Returns the empty line and its width.
---@param tagRows wonderland.Element[]
---@param tagLine wonderland.Element[]
---@param lineStyle wonderland.StyleBuilder
---@return wonderland.Element[]
---@return number
local function flushTagLine(tagRows, tagLine, lineStyle)
	if #tagLine == 0 then return tagLine, 0 end
	tagRows[#tagRows + 1] = div():style(lineStyle):children(tagLine)
	return {}, 0
end

--- The tags worth drawing, kept against the taxonomy revision: the page asks every frame, and the
--- answer is the same list until a tag is made, renamed or removed.
---@type { taxonomy: beat.Taxonomy, revision: number, tags: beat.Tag[] }?
local tagsCache

---@param taxonomy beat.Taxonomy
local function visibleTags(taxonomy)
	local kept = tagsCache
	if kept == nil or kept.taxonomy ~= taxonomy or kept.revision ~= taxonomy.revision then
		kept = { taxonomy = taxonomy, revision = taxonomy.revision, tags = taxonomy:visibleTags() }
		tagsCache = kept
	end
	return kept.tags
end

local NEW_TAG = { type = "open", overlay = "tag_dialog" }

-- The four headings' props, written again for each heading: the component reads them and keeps
-- nothing, so one table serves the page.
local sectionProps = {}

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
	local tags = visibleTags(taxonomy)

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
	local shelf = styles.of(theme, "playlistsShelf", tileWidth) --[[@as { style: wonderland.StyleBuilder? }]]
	local rowStyle = shelf.style
	if rowStyle == nil then
		rowStyle = sty():row():wrel(1.0):h(tileHeight):gap(gap)
		shelf.style = rowStyle
	end
	rowStyle = assert(rowStyle)

	local smartTiles = {}
	for _, playlist in ipairs(Smart.all()) do
		smartTiles[#smartTiles + 1] = playlistTile(app, playlist, app.services.collections:playlistTracks(playlist), true, tileWidth, mobile, ctx)
	end

	-- The automatic playlist a tag carries is shown as the tag itself below; this grid is the
	-- lists the listener chose to make.
	---@type beat.Playlist[]
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
		ownTiles[#ownTiles + 1] = playlistTile(app, playlist, app.services.collections:playlistTracks(playlist), false, tileWidth, mobile, ctx)
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

	local lineBox = styles.of(theme, "playlistsTagLine", pillHeight) --[[@as { style: wonderland.StyleBuilder?, gap: number? }]]
	local lineStyle = lineBox.style
	if lineStyle == nil or lineBox.gap ~= pillGap then
		lineBox.gap = pillGap
		lineStyle = sty():row():wrel(1.0):h(pillHeight):gap(pillGap)
		lineBox.style = lineStyle
	end
	lineStyle = assert(lineStyle)
	for _, tag in ipairs(tags) do
		local countText = tostring(tag.count)
		-- The measured widths and the pill's own boxes are the same until the tag, its count or the
		-- room it has change: they are kept with the tag rather than measured and built again on
		-- every frame of a scroll.
		local kept = tagStyles[tag]
		if
			kept == nil
			or kept.theme ~= theme
			or kept.mix ~= theme.mix
			or kept.mobile ~= mobile
			or kept.content ~= content
			or kept.nameSize ~= nameSize
			or kept.countText ~= countText
			or kept.name ~= tag.name
			or kept.pillHeight ~= pillHeight
		then
			---@type beat.pages.PlaylistsPillStyles
			local built
			local baseStyle = theme:s():text(theme:type("xs"))
			local countFallback = math.floor(#countText * theme:type("xs") * 0.7)
			local countWidth = math.max(
				theme:px(12),
				math.ceil(math.max(measure.width(app, countText, baseStyle) or 0, countFallback)) + 1
			)
			local nameBase = theme:s():text(nameSize):weight("semibold")
			local nameFallback = measure.estimate(tag.name, nameSize, 0.54)
			local nameWidth = math.max(
				theme:px(16),
				math.ceil(math.max(measure.width(app, tag.name, nameBase) or 0, nameFallback)) + 1
			)
			-- The row break is manual because Wonderland has no wrap container, but each pill's
			-- width comes from the same measured runs the text is drawn with.
			local estimatedWidth = pillPadLeft + pillPadRight + countWidth + nameWidth + closeWidth + gaps
			estimatedWidth = math.min(content, math.max(theme:px(64), estimatedWidth))
			nameWidth = math.max(theme:px(16), estimatedWidth - pillPadLeft - pillPadRight - countWidth - closeWidth - gaps)
			local parts = pillParts(theme, closeWidth, pillHeight, 0)
			local editWidth = math.min(content, math.max(estimatedWidth, theme:px(mobile ? 240 : 190)))
			built = {
				theme = theme,
				mix = theme.mix,
				mobile = mobile,
				content = content,
				nameSize = nameSize,
				countText = countText,
				name = tag.name,
				pillHeight = pillHeight,
				estimatedWidth = estimatedWidth,
				countStyle = baseStyle:w(countWidth):fg(theme:color("faint")):ellipsis(),
				nameStyle = nameBase:w(nameWidth):fg(theme:color("text")):ellipsis(),
				pill = sty()
					:row():w(estimatedWidth):h(pillHeight):gap(theme:px(6)):pad(0, pillPadRight, 0, pillPadLeft):align("center")
					:radius(theme:radius("full")):bg(theme:color("elevated")):border(theme:px(1), theme:color("border")),
				hover = sty()
					:row():w(estimatedWidth):h(pillHeight):gap(theme:px(6)):pad(0, pillPadRight, 0, pillPadLeft):align("center")
					:radius(theme:radius("full")):bg(theme:color("hover")):border(theme:px(1), theme:color("border")),
				closeBox = parts.closeBox,
				editPill = sty()
					:row():w(editWidth):h(pillHeight):gap(theme:px(4)):pad(0, theme:px(8), 0, theme:px(8)):align("center")
					:radius(theme:radius("full")):bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
			}
			tagStyles[tag] = built
			kept = built
		end
		kept = assert(kept)

		local acts = actionsFor(tag)
		local editing = state.tagEditId == tag.id
		local pill
		local usedWidth = kept.estimatedWidth
		if editing then
			local editWidth = math.min(content, math.max(kept.estimatedWidth, theme:px(mobile ? 240 : 190)))
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
					oninput = tagEditTyped,
					onsubmit = submitRename,
					width = fieldWidth
				}
			)
			pill = div()
				:style(kept.editPill)
				:children(
					nameField,
					ui.iconButton(ctx, { name = "check", size = editCheck, onClick = { type = "renameTag" } }),
					ui.iconButton(ctx, { name = "close", size = editCancel, onClick = { type = "cancelTagEdit" } })
				)
		else
			pill = div()
				:style(kept.pill)
				:hover(kept.hover)
				:onMouseMove(acts.hover)
				:children(
					text(countText):style(kept.countStyle),
					text(tag.name):style(kept.nameStyle):onClick(acts.edit),
					div()
						:style(kept.closeBox)
						:onClick(acts.delete)
						:children(text("×"):style(pillParts(theme, closeWidth, pillHeight, 0).closeText))
				)
		end
		if lineWidth > 0 and lineWidth + pillGap + usedWidth > content then tagLine, lineWidth = flushTagLine(tagRows, tagLine, lineStyle) end
		tagLine[#tagLine + 1] = pill
		lineWidth = lineWidth + (lineWidth > 0 and pillGap or 0) + usedWidth
	end

	-- The last pill makes a new tag: accent-edged like the New playlist tile, so the two ways to
	-- make something look alike, and placed where the tag it makes will appear.
	local newLabel = "New tag"
	local newLabelStyles = styles.of(theme, "playlistsNewLabel", nameSize) --[[@as { base: wonderland.StyleBuilder?, label: wonderland.StyleBuilder?, width: number? }]]
	local labelBase = newLabelStyles.base
	if labelBase == nil then
		labelBase = theme:s():text(nameSize):weight("semibold")
		newLabelStyles.base = labelBase
	end
	local newLabelWidth = math.ceil(
		math.max(measure.width(app, newLabel, assert(labelBase)) or 0, measure.estimate(newLabel, nameSize, 0.54)) + 1
	)
	local labelText = newLabelStyles.label
	if labelText == nil or newLabelStyles.width ~= newLabelWidth then
		labelText = theme:s():w(newLabelWidth):text(nameSize):weight("semibold"):fg(theme:color("accent"))
		newLabelStyles.width, newLabelStyles.label = newLabelWidth, labelText
	end
	local newIconSize = theme:px(mobile and 18 or 15)
	local newWidth = pillPadLeft + newIconSize + theme:px(6) + newLabelWidth + theme:px(14)
	local parts = pillParts(theme, closeWidth, pillHeight, newWidth)
	local newPill = div()
		:style(assert(parts.newPill)):hover(assert(parts.newPillHover))
		:onClick(NEW_TAG)
		:children(
			ui.icon(ctx, { name = "add", size = newIconSize, colour = theme:color("accent") }),
			text(newLabel):style(assert(labelText))
		)
	if lineWidth > 0 and lineWidth + pillGap + newWidth > content then tagLine, lineWidth = flushTagLine(tagRows, tagLine, lineStyle) end
	tagLine[#tagLine + 1] = newPill
	lineWidth = lineWidth + (lineWidth > 0 and pillGap or 0) + newWidth
	tagLine, lineWidth = flushTagLine(tagRows, tagLine, lineStyle)

	local tagHeight = #tagRows * pillHeight + math.max(0, #tagRows - 1) * pillGap
	if #tags == 0 then
		-- With no tags yet the pill alone does not say what a tag is for.
		tagRows[#tagRows + 1] = text("A tag is also a smart playlist.")
			:style(theme:s():wrel(1.0):h(emptyTagHeight):text(theme:type("sm")):fg(theme:color("muted")))
		tagHeight = tagHeight + pillGap + emptyTagHeight
	end
	local sectionHeight = theme:px(24)
	local sectionGap = theme:space(18)
	local smartHeight = gridHeightFor(#smartTiles, columns, tileHeight, gap)
	local ownHeight = gridHeightFor(#ownTiles, columns, tileHeight, gap)

	local children = { header }
	local height = headerHeight
	sectionProps.title = "Smart playlists"
	children[#children + 1] = ui.section(ctx, sectionProps)
	height = height + sectionGap + sectionHeight
	children[#children + 1] = div():style(columnStyle(theme, smartHeight, gap)):children(gridRows(smartTiles, columns, rowStyle))
	height = height + sectionGap + smartHeight
	sectionProps.title = "Your playlists"
	children[#children + 1] = ui.section(ctx, sectionProps)
	height = height + sectionGap + sectionHeight
	children[#children + 1] = div():style(columnStyle(theme, ownHeight, gap)):children(gridRows(ownTiles, columns, rowStyle))
	height = height + sectionGap + ownHeight
	sectionProps.title = "Tags"
	children[#children + 1] = ui.section(ctx, sectionProps)
	height = height + sectionGap + sectionHeight
	children[#children + 1] = div():style(columnStyle(theme, tagHeight, pillGap)):children(tagRows)
	height = height + sectionGap + tagHeight

	app.services.scroll:setLimit(app:pageKey(), metrics.pageScrollLimit(app, window, height))

	return div():style(columnStyle(theme, height, sectionGap)):children(children)
end

return playlists
