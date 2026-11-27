-- The tags an item carries, one row each, over the same panel a playlist picker draws: a create
-- row leads the list, a row toggles its tag on the whole item, and an empty panel says so and
-- offers the one thing there is to do about it. Clicking the dark area dismisses it; clicking the
-- panel itself does not.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local metrics = require("beat.app.components.helpers.metrics")
local styleCache = require("beat.app.components.helpers.styles")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.TagPickerState
---@field kind "album"|"track"
---@field id number
---@field newTag table # The message that opens the new-tag dialog for this item

---@class beat.TagPickerStyles
---@field header wonderland.StyleBuilder
---@field title wonderland.StyleBuilder
---@field rowHeight number
---@field rowPadding number
---@field rowGap number
---@field name wonderland.StyleBuilder
---@field createName wonderland.StyleBuilder
---@field badge wonderland.StyleBuilder
---@field divider wonderland.StyleBuilder
---@field dividerRow wonderland.StyleBuilder
---@field checkBox wonderland.StyleBuilder
---@field emptyIcon wonderland.StyleBuilder
---@field emptyTitle wonderland.StyleBuilder
---@field emptyCopy wonderland.StyleBuilder
---@field check number # The square a row's trailing mark, or the gap where one would be, keeps

-- Every panel a picker draws shares these: the row's one height, padding and gap, the mark the
-- create row and each tag lead with, and the empty state's mark, title and copy. They are built
-- once per theme and panel width, not once per frame: the labels are boxes of their own so a long
-- name ellipsizes before it reaches the check, which is why the width is part of the key.
---@type table<beat.Theme, table<number, beat.TagPickerStyles>>
local stylesByTheme = setmetatable({}, { __mode = "k" })

---@param theme beat.Theme
---@param content number # The panel's inner width, which every box below is cut to
---@return beat.TagPickerStyles
local function pickerStyles(theme, content)
	local byContent = stylesByTheme[theme]
	if byContent == nil then
		byContent = {}
		stylesByTheme[theme] = byContent
	end
	local styles = byContent[content]
	if styles == nil then
		local rowHeight = theme:px(38)
		local rowPadding = theme:px(10)
		local rowGap = theme:px(8)
		local badgeSize = theme:px(24)
		local check = theme:px(16)
		local inner = content - rowPadding * 2
		styles = {
			header = sty():row():wrel(1.0):h(theme:px(28)):gap(rowGap):align("center"):justify("space-between"),
			title = theme:s()
				:w(content - theme:px(28) - rowGap):text(theme:type("lg")):weight("bold"):fg(theme:color("text")):ellipsis(),
			rowHeight = rowHeight,
			rowPadding = rowPadding,
			rowGap = rowGap,
			-- A tag row's three boxes sit inside the row's padding with a gap between each, so the
			-- name keeps clear of the trailing check even when it is the longest word in the panel.
			name = theme:s()
				:w(math.max(theme:px(1), inner - badgeSize - check - rowGap * 2)):text(theme:type("sm")):fg(theme:color("text"))
				:ellipsis(),
			createName = theme:s()
				:w(math.max(theme:px(1), inner - badgeSize - rowGap)):text(theme:type("sm")):weight("semibold")
				:fg(theme:color("text")):ellipsis(),
			badge = sty()
				:size(badgeSize, badgeSize):radius(theme:radius("full")):bg(theme:color("accent", 0.14)):row():align("center")
				:justify("center"),
			divider = sty():wrel(1.0):h(theme:px(1)):bg(theme:color("border")),
			dividerRow = sty():wrel(1.0):h(theme:px(13)):pad(theme:px(6), 0, theme:px(6), 0),
			checkBox = sty():size(check, check),
			emptyIcon = sty()
				:size(theme:px(56), theme:px(56)):radius(theme:radius("full")):bg(theme:color("accent", 0.14)):row():align("center")
				:justify("center"),
			emptyTitle = theme:s():text(theme:type("lg")):weight("semibold"):fg(theme:color("text")),
			emptyCopy = theme:s():text(theme:type("sm")):fg(theme:color("muted")),
			check = check
		}
		byContent[content] = styles
	end
	return styles
end

-- The tags the panel lists, kept against the taxonomy revision: a frame asks every time and the
-- answer is the same list until a tag is made, renamed or removed.
---@type { taxonomy: beat.Taxonomy, revision: number, tags: beat.Tag[] }?
local tagsCache

---@param taxonomy beat.Taxonomy
---@return beat.Tag[]
local function visibleTags(taxonomy)
	local kept = tagsCache
	if kept == nil or kept.taxonomy ~= taxonomy or kept.revision ~= taxonomy.revision then
		kept = { taxonomy = taxonomy, revision = taxonomy.revision, tags = taxonomy:visibleTags() }
		tagsCache = kept
	end
	return kept.tags
end

-- A row's press message is the same for the life of its tag, so it is made once rather than once
-- per row per frame; the tags are held weakly so a removed tag takes its message with it.
---@type table<beat.Tag, table>
local toggleMessages = setmetatable({}, { __mode = "k" })

---@param tag beat.Tag
---@return table
local function toggleMessage(tag)
	local message = toggleMessages[tag]
	if message == nil then
		message = { type = "toggleItemTag", id = tag.id }
		toggleMessages[tag] = message
	end
	return message
end

---@class beat.TagPickerOverlay: beat.OverlaySurface
local tagPicker = {}

---@param params { kind: "album"|"track"?, id: number? }
---@param app beat.App
function tagPicker.new(app, params)
	local kind = params.kind == "album" and "album" or "track"
	local library = app.services.library.current
	local id
	if kind == "album" then
		local album = library ~= nil and params.id ~= nil and library:album(params.id) or nil
		if album == nil then return nil end
		id = album.id
	else
		local track = params.id ~= nil and library ~= nil and library:track(params.id) or app.services.playback:current()
		if track == nil then return nil end
		id = track.id
	end
	---@type beat.TagPickerState
	return { kind = kind, id = id, newTag = { type = "open", overlay = "tag_dialog", kind = kind, id = id } }
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.TagPickerState>
---@param message beat.Message
function tagPicker.update(app, overlay, message)
	local state = overlay.state
	if message.type == "toggleItemTag" then
		if app.services.collections.taxonomy.tagById[message.id] ~= nil then
			app.services.collections:toggleItemTag(state.kind, state.id, message.id)
			app:refresh()
		end
		return true
	end
	return false
end

--- The create row, or one tag: a soft accent mark, the name, and the trailing check that says
--- whether the item already carries it. The row is the shared list row, so its hover and press
--- fill are the panel's inner width and its content sits inside that fill, on one line.
---@param app beat.App
---@param ctx beat.ui.Context
---@param tag beat.Tag?
---@param checked boolean
---@param newTag table?
---@param styles beat.TagPickerStyles
---@return wonderland.Element
local function pickerRow(app, ctx, tag, checked, newTag, styles)
	local theme = app.services.appearance.theme
	local children
	if tag == nil then
		children = {
			div()
				:style(styles.badge):children({ ui.icon(ctx, { name = "add", size = theme:px(14), colour = theme:color("text") }) }),
			text("New tag"):style(styles.createName)
		}
	else
		local trailing
		if checked then
			trailing = ui.icon(ctx, { name = "check", size = styles.check, colour = theme:color("accent") })
		else
			trailing = div():style(styles.checkBox)
		end
		children = {
			div()
				:style(styles.badge)
				:children({ ui.icon(ctx, { name = "tag", size = theme:px(13), colour = theme:color("accent") }) }),
			text(tag.name):style(styles.name),
			trailing
		}
	end
	return ui.listRow(
		ctx,
		{
			height = styles.rowHeight,
			padding = styles.rowPadding,
			gap = styles.rowGap,
			justify = "start",
			onClick = tag ~= nil and toggleMessage(tag) or newTag,
			children = children
		}
	)
end

--- How tall one line of text stands, close enough that the panel is cut to it before layout runs.
---@param size number
---@return number
local function lineHeight(size)
	return math.floor(size * 1.35)
end

--- The panel's boxes, kept for the size they were built at: the dialog is rebuilt on every frame it
--- is open, and only the number of tags, the window and the sheet change any of them.
---@class beat.TagPickerFrame
---@field width number
---@field height number
---@field under number
---@field inset number
---@field sheet boolean
---@field windowWidth number
---@field windowHeight number
---@field listHeight number
---@field itemGap number
---@field emptyGap number
---@field list wonderland.StyleBuilder
---@field emptyBlock wonderland.StyleBuilder
---@field panel wonderland.StyleBuilder
---@field sheetBox wonderland.StyleBuilder
---@field overlay wonderland.StyleBuilder

---@param theme beat.Theme
---@param width number
---@param height number
---@param under number
---@param inset number
---@param sheet boolean
---@param listHeight number? # nil when the panel lists no tags
---@param itemGap number
---@param emptyGap number
---@param pad number
---@param gap number
---@param window wonderland.RenderWindow
---@return beat.TagPickerFrame
local function pickerFrame(theme, width, height, under, inset, sheet, listHeight, itemGap, emptyGap, pad, gap, window)
	local byKey = styleCache.of(theme, "tagPickerFrame", width)
	local frame = byKey[0] --[[@as beat.TagPickerFrame?]]
	if
		frame ~= nil
		and frame.height == height
		and frame.under == under
		and frame.inset == inset
		and frame.sheet == sheet
		and frame.listHeight == listHeight
		and frame.itemGap == itemGap
		and frame.emptyGap == emptyGap
		and frame.windowWidth == window.width
		and frame.windowHeight == window.height
	then
		return frame
	end

	local radius = theme:radius("lg")
	frame = {
		width = width,
		height = height,
		under = under,
		inset = inset,
		sheet = sheet,
		listHeight = listHeight,
		itemGap = itemGap,
		emptyGap = emptyGap,
		windowWidth = window.width,
		windowHeight = window.height,
		list = sty():column():wrel(1.0):h(listHeight or 0):gap(itemGap),
		emptyBlock = sty():column():wrel(1.0):gap(emptyGap):align("center"),
		panel = sty()
			:w(width):h(height + under):column():pad(pad, pad, pad + under, pad):gap(gap):radius(radius)
			:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
			:shadow(0, theme:px(12), theme:px(30), "#00000080"),
		sheetBox = sty():w(width):h(height + inset),
		overlay = sty()
			:size(window.width, window.height):offset(0, 0):z(121):column():align("center")
			:justify(sheet ? "end" : "center"):bg(theme:color("overlay"))
	}
	byKey[0] = frame
	return frame
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.TagPickerState>
---@param window wonderland.RenderWindow
function tagPicker.view(app, overlay, window)
	local state = overlay.state
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local tags = visibleTags(app.services.collections.taxonomy)
	local sheet = ctx.mobile

	local width = sheet and window.width or ctx:panelWidth(360)
	local pad = theme:px(sheet and 20 or 16)
	local gap = theme:px(sheet and 16 or 14)
	local content = width - pad * 2
	local headerHeight = theme:px(28)
	local styles = pickerStyles(theme, content)

	local count = #tags
	-- The tags the item carries, as a set read once per frame: a row asks whether its own id is in
	-- it, rather than an album walking every track it has for every tag in the list.
	local checkedTags = app.services.collections:itemTagSet(state.kind, state.id)
	local rows = {}
	if count > 0 then
		-- The create row leads the list, as it does in the playlist picker: making a tag is the
		-- other thing a listener comes here to do, and it costs one row to keep both answers in
		-- the same place.
		rows[#rows + 1] = pickerRow(app, ctx, nil, false, state.newTag, styles)
		rows[#rows + 1] = div():style(styles.dividerRow):children({ div():style(styles.divider) })
		for at = 1, count do
			local tag = tags[at]
			rows[#rows + 1] = pickerRow(app, ctx, tag, checkedTags[tag.id] == true, nil, styles)
		end
	end

	---@type wonderland.Element[]
	local children = {
		div()
			:style(styles.header)
			:children(
				{
					text(state.kind == "album" ? "Tag album" : "Tag track"):style(styles.title),
					ui.iconButton(ctx, { name = "close", size = theme:px(28), onClick = { type = "dismiss" } })
				}
			)
	}

	local height = pad * 2 + headerHeight
	local itemGap = theme:px(2)
	local emptyGap = theme:px(14)
	local listHeight, emptyCopy
	if count == 0 then
		emptyCopy = state.kind == "album" and "Create one and this album is tagged straight away." or "Create one and this track is tagged straight away."
		local titleSize = theme:type("lg")
		local copySize = theme:type("sm")
		local blockHeight = theme:px(56) + lineHeight(titleSize) + lineHeight(copySize) + theme:px(36) + emptyGap * 3
		height += gap + blockHeight
	else
		listHeight = (count + 1) * styles.rowHeight + theme:px(13) + (count + 1) * itemGap
		height += gap + listHeight
	end

	-- On a phone the panel is a sheet that rises from the bottom edge, its lower corners pushed past
	-- the screen and its foot clearing the gesture bar, as the playlist picker's sheet does.
	local _, inset = metrics.insets()
	local radius = theme:radius("lg")
	local under = sheet and (inset + radius) or 0
	local frame = pickerFrame(theme, width, height, under, inset, sheet, listHeight, itemGap, emptyGap, pad, gap, window)

	if count == 0 then
		children[#children + 1] = div()
			:style(frame.emptyBlock)
			:children(
				{
					div()
						:style(styles.emptyIcon)
						:children({ ui.icon(ctx, { name = "tag", size = theme:px(26), colour = theme:color("accent") }) }),
					text("No tags yet"):style(styles.emptyTitle),
					text(assert(emptyCopy)):style(styles.emptyCopy),
					ui.button(
						ctx,
						{
							label = "New tag",
							icon = "add",
							onClick = state.newTag,
							variant = "primary",
							height = theme:px(36),
							width = theme:px(160)
						}
					)
				}
			)
	else
		children[#children + 1] = div():style(frame.list):children(rows)
	end

	local panel = div():style(frame.panel):onClick({ type = "keep" }):children(children)
	if sheet then panel = div():style(frame.sheetBox):children({ panel }) end

	return div():style(frame.overlay):onClick({ type = "dismiss" }):children({ panel })
end

return tagPicker
