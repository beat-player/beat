-- The grouped list the settings and plugins pages are made of: a small heading over a rounded box
-- of rows, a hairline between each row. A row says what it is on the left -- a label and a line
-- under it -- and holds its control on the right; where the row is too narrow for both side by
-- side, the control goes under the words instead. The controls a row usually holds are here too:
-- a segmented choice, an on/off switch and a small badge.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local measure = require("beat.app.components.helpers.measure")
local styles = require("beat.app.components.helpers.styles")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local settingsList = {}

--- The boxes of one group, kept for the width and the height the rows come to. A settings page is
--- built again on every scroll step, and its rows do not change between them.
---@class beat.components.SettingsGroupStyles
---@field boxHeight number?
---@field box wonderland.StyleBuilder
---@field separator wonderland.StyleBuilder
---@field height number?
---@field heading wonderland.StyleBuilder
---@field outer wonderland.StyleBuilder

--- The boxes and the text styles of one row, kept for the shape of the row: its width, how much
--- room the control takes, whether there is a line under the label, and whether it is drawn
--- quieter. Each `beat.components.SettingsRowStyles` in `byShape` is one of those.
---@class beat.components.SettingsRowStyles
---@field textWidth number
---@field textHeight number
---@field height number
---@field label wonderland.StyleBuilder
---@field description wonderland.StyleBuilder?
---@field words wonderland.StyleBuilder
---@field element wonderland.StyleBuilder
---@field content wonderland.StyleBuilder
---@field row wonderland.StyleBuilder?
---@field hover wonderland.StyleBuilder?

---@class beat.components.SettingsListStyles
---@field separator wonderland.StyleBuilder?
---@field groups table<number, beat.components.SettingsGroupStyles>
---@field rows table<number, table<number, table<number, beat.components.SettingsRowStyles>>>
---@field toggles table<number, { track: wonderland.StyleBuilder, knob: wonderland.StyleBuilder }>
---@field badges table<string, { box: wonderland.StyleBuilder, text: wonderland.StyleBuilder, width: number }>
---@field segments table<string, table>

-- Below this many theme pixels of row width the control goes under the label rather than beside it.
local STACK_BELOW = 520

---@class beat.components.SettingsItem
---@field element wonderland.Element
---@field height number

--- The width a page's settings column takes: the content width, but no wider than reads well.
---@param app beat.App
---@param content number # The page's content width
---@return number
function settingsList.columnWidth(app, content)
	return math.min(content, app.services.appearance.theme:px(760))
end

--- Whether a row of this width stacks its control under its words.
---@param app beat.App
---@param width number
---@return boolean
function settingsList.stacked(app, width)
	return width < app.services.appearance.theme:px(STACK_BELOW)
end

--- The height of a group's rows and the hairlines between them.
---@param rows beat.components.SettingsItem[]
---@param count number
---@return number
local function rowsHeight(rows, count)
	local height = 0
	for at = 1, count do
		if at > 1 then height += 1 end
		height += rows[at].height
	end
	return height
end

--- The rows added to a group's box, a hairline between each pair. The loop is its own function
--- so it compiles even when the page that asked for the group is still being interpreted.
---@param box wonderland.Element
---@param rows beat.components.SettingsItem[]
---@param count number
---@param separator wonderland.StyleBuilder
local function addRows(box, rows, count, separator)
	for at = 1, count do
		if at > 1 then box:children(div():style(separator)) end
		box:children(rows[at].element)
	end
end

---@class beat.components.SettingsGroupProps
---@field title string? # The heading over the box
---@field rows beat.components.SettingsItem[]
---@field width number

--- A heading and the box of rows under it. Returns the element and its height.
---@param app beat.App
---@param props beat.components.SettingsGroupProps
---@return wonderland.Element
---@return number
function settingsList.group(app, props)
	local theme = app.services.appearance.theme
	local width = props.width
	local kept = styles.of(theme, "settingsList", width) --[[@as beat.components.SettingsListStyles]]
	local groups = kept.groups
	if groups == nil then
		groups = {}
		kept.groups = groups
	end
	local separator = kept.separator
	if separator == nil then
		separator = sty():wrel(1.0):h(1):margin(0, theme:px(16), 0, theme:px(16)):bg(theme:color("border"))
		kept.separator = separator
	end
	separator = assert(separator)
	local rowCount = #props.rows
	local boxHeight = rowsHeight(props.rows, rowCount)

	local group = groups[0]
	if group == nil or group.boxHeight ~= boxHeight then
		group = { boxHeight = boxHeight }
		-- The inset is the rows' own horizontal padding rather than the card's: a row that can be
		-- hovered or pressed is then as wide as the card's inside and its highlight covers the
		-- padding too, instead of stopping at the text.
		group.box = sty()
			:column():w(width):h(boxHeight):radius(theme:radius("md"))
			:bg(theme:color("surface")):border(theme:px(1), theme:color("border"))
		groups[0] = group
	end
	-- The rows are handed over one at a time: a group is built on every frame of a scroll, and a
	-- table it is only a list of is a table the frame does not need.
	local box = div():style(group.box)
	addRows(box, props.rows, rowCount, separator)
	if props.title == nil then return box, boxHeight end

	local headingHeight = math.floor(theme:type("sm") * 1.4)
	local gap = theme:px(8)
	local height = headingHeight + gap + boxHeight
	local titled = groups[height]
	if titled == nil then
		titled = {
			height = height,
			heading = theme:s():w(width):h(headingHeight):text(theme:type("sm")):weight("semibold"):fg(theme:color("muted")):ellipsis(),
			outer = sty():column():w(width):h(height):gap(gap)
		}
		groups[height] = titled
	end
	local heading = text(props.title):style(titled.heading)
	return div():style(titled.outer):children(heading, box), height
end

---@class beat.components.SettingsRowProps
---@field label string
---@field description string? # One line under the label, cut to fit
---@field control wonderland.Element? # What the row holds on the right, or under the words when stacked
---@field controlWidth number? # How wide the control is; required with `control`
---@field controlHeight number? # How tall it is; default px(32)
---@field width number # The group's width; the row is its inner width
---@field dim boolean? # Drawn quieter: a row that is shown but cannot be changed
---@field onClick any? # The whole row is a target, as a link to another page is
---@field badge wonderland.Element? # Something small after the label, such as a version
---@field badgeWidth number?

--- One row from the props record, filling `item` when the caller keeps one: a page built again on
--- every scroll step asks for its rows again, and the record a group reads is the caller's to hand
--- back.
---@param app beat.App
---@param props beat.components.SettingsRowProps
---@param item beat.components.SettingsItem?
---@return beat.components.SettingsItem
local function buildRow(app, props, item)
	local theme = app.services.appearance.theme
	-- The room a row has for its words and control: the card's inside, less the horizontal
	-- padding the row itself carries, so a highlight on the row can cover that padding too.
	local inner = props.width - theme:px(34)
	local labelSize = theme:type("base")
	local descriptionSize = theme:type("sm")
	local labelHeight = math.floor(labelSize * 1.35)
	local descriptionHeight = props.description ~= nil and math.floor(descriptionSize * 1.4) or 0
	local textHeight = labelHeight + (props.description ~= nil and (theme:px(2) + descriptionHeight) or 0)
	local controlWidth = props.control ~= nil and (props.controlWidth or 0) or 0
	local controlHeight = props.control ~= nil and (props.controlHeight or theme:px(32)) or 0
	-- A narrow row stacks only a control that would crowd the words: a switch or a badge still fits
	-- beside them, and stacking it would leave a line of nothing but a small mark.
	local stacked = props.control ~= nil and settingsList.stacked(app, props.width) and controlWidth > inner * 0.35
	local padY = theme:px(14)
	local gap = theme:px(16)

	-- The row's own boxes and text styles are a function of the shape built above and the room the
	-- control takes: the same shape comes back on every frame of a page that is being scrolled.
	local kept = styles.of(theme, "settingsList", props.width) --[[@as beat.components.SettingsListStyles]]
	local rowsCache = kept.rows
	if rowsCache == nil then
		rowsCache = {}
		kept.rows = rowsCache
	end
	local shape = (props.control ~= nil and 1 or 0) + (props.description ~= nil and 2 or 0) + (stacked and 4 or 0)
	if props.dim then shape += 8 end
	if props.onClick ~= nil then shape += 16 end
	local byControl = rowsCache[shape]
	if byControl == nil then
		byControl = {}
		rowsCache[shape] = byControl
	end
	local byHeight = byControl[controlWidth]
	if byHeight == nil then
		byHeight = {}
		byControl[controlWidth] = byHeight
	end
	local s = byHeight[controlHeight]
	if s == nil then
		local textWidth = stacked and inner or math.max(theme:px(80), inner - (controlWidth > 0 and (controlWidth + gap) or 0))
		local labelColour = props.dim and theme:color("muted") or theme:color("text")
		local descriptionColour = props.dim and theme:color("faint") or theme:color("muted")
		local height = stacked and (padY * 2 + textHeight + theme:px(10) + controlHeight)
			or (padY * 2 + math.max(textHeight, controlHeight))
		s = {
			textWidth = textWidth,
			height = height,
			label = theme:s():w(textWidth):h(labelHeight):text(labelSize):weight("medium"):fg(labelColour):ellipsis(),
			description = props.description ~= nil
					and (theme:s():w(textWidth):h(descriptionHeight):text(descriptionSize):fg(descriptionColour):ellipsis())
				or nil,
			words = sty():column():w(textWidth):h(textHeight):gap(theme:px(2)),
			-- A row without a click owns its inset, and sits across the card on its own.
			element = stacked
					and (sty():column():wrel(1.0):h(height):pad(padY, theme:px(16), padY, theme:px(16)):gap(theme:px(10)))
				or (sty():row():wrel(1.0):h(height):pad(0, theme:px(16), 0, theme:px(16)):gap(gap):align("center"):justify("space-between")),
			-- A row that can be clicked puts the same inset inside a box as wide as the card's
			-- inside, so hovering or pressing lights the padding as well as the words. Its radius
			-- is the card's: a row's highlight runs into the rounded corners it meets.
			content = stacked
					and (sty():column():w(inner):h(height):pad(padY, 0, padY, 0):gap(theme:px(10)))
				or (sty():row():w(inner):h(height):gap(gap):align("center"):justify("space-between")),
			row = props.onClick ~= nil
					and (sty():wrel(1.0):h(height):pad(0, theme:px(16), 0, theme:px(16)):radius(theme:radius("md")))
				or nil,
			hover = props.onClick ~= nil
					and (sty():wrel(1.0):h(height):pad(0, theme:px(16), 0, theme:px(16)):radius(theme:radius("md"))
						:bg(theme:color("hover", 0.5)))
				or nil
		}
		byHeight[controlHeight] = s
	end

	local labelRow
	if props.badge ~= nil then
		local badgeWidth = props.badgeWidth or 0
		local badgeRow = kept.badges --[[@as table<string, { row: wonderland.StyleBuilder, label: wonderland.StyleBuilder, badgeWidth: number, textWidth: number }>?]]
		if badgeRow == nil then
			badgeRow = {}
			kept.badges = badgeRow
		end
		local known = badgeRow[props.label]
		if known == nil or known.badgeWidth ~= badgeWidth or known.textWidth ~= s.textWidth or known.dim ~= props.dim then
			local labelStyle = theme:s():text(labelSize):weight("medium")
			local natural = math.ceil(measure.width(app, props.label, labelStyle) or s.textWidth) + 1
			local labelWidth = math.max(theme:px(24), math.min(natural, s.textWidth - badgeWidth - theme:px(8)))
			known = {
				badgeWidth = badgeWidth,
				textWidth = s.textWidth,
				dim = props.dim,
				row = sty():row():w(s.textWidth):h(labelHeight):gap(theme:px(8)):align("center"),
				label = theme:s():w(labelWidth):text(labelSize):weight("medium"):fg(theme:color("text")):ellipsis()
			}
			if props.dim then known.label = theme:s():w(labelWidth):text(labelSize):weight("medium"):fg(theme:color("muted")):ellipsis() end
			badgeRow[props.label] = known
		end
		labelRow = div():style(known.row):children(text(props.label):style(known.label), props.badge)
	else
		labelRow = text(props.label):style(s.label)
	end

	local words = div():style(s.words):children(labelRow)
	local description, descriptionStyle = props.description, s.description
	if description ~= nil and descriptionStyle ~= nil then words:children(text(description):style(descriptionStyle)) end

	local element
	local control = props.control
	if props.onClick ~= nil then
		local content = div():style(s.content):children(words)
		if control ~= nil then content:children(control) end
		element = ui.ripple(
			div():style(assert(s.row)):hover(assert(s.hover)):onClick(props.onClick):children(content),
			nil,
			theme:color("text")
		)
	else
		local plain = div():style(s.element):children(words)
		if control ~= nil then plain:children(control) end
		element = plain
	end
	item = item or {}
	item.element, item.height = element, s.height
	return item
end

--- One row. Returns the element and its height.
---@param app beat.App
---@param props beat.components.SettingsRowProps
---@return beat.components.SettingsItem
function settingsList.row(app, props)
	return buildRow(app, props, nil)
end

-- The props a positional row is built from, written for each row: the row reads them and keeps
-- nothing, so one record serves every row of a page.
---@type beat.components.SettingsRowProps
local ROW = { label = "", width = 0 }

--- One row without a props table. `item` is the caller's record to fill (one per row, kept across
--- frames), so a page that builds the same rows every frame makes neither.
---@param app beat.App
---@param item beat.components.SettingsItem
---@param width number
---@param label string
---@param description string?
---@param control wonderland.Element?
---@param controlWidth number?
---@param controlHeight number?
---@param onClick any?
---@param badge wonderland.Element?
---@param badgeWidth number?
---@return beat.components.SettingsItem
function settingsList.rowAt(app, item, width, label, description, control, controlWidth, controlHeight, onClick, badge, badgeWidth)
	ROW.width, ROW.label, ROW.description = width, label, description
	ROW.control, ROW.controlWidth, ROW.controlHeight = control, controlWidth, controlHeight
	ROW.onClick, ROW.badge, ROW.badgeWidth = onClick, badge, badgeWidth
	return buildRow(app, ROW, item)
end

---@class beat.components.SettingsOption
---@field label string
---@field message any # What choosing it sends
---@field selected boolean

---@class beat.components.SegmentedProps
---@field options beat.components.SettingsOption[]
---@field width number? # Fill this width, options sharing it equally; default each option's own width
---@field height number? # Default px(32)

--- One option's fill in a segmented pill: a width, the height inside the pill's inset, and the
--- colour the option is. It is a function of its own rather than one declared in the loop that
--- builds the choices, so the frame that draws a settings row makes no closure.
---@param theme beat.Theme
---@param width number
---@param height number
---@param inset number
---@param fill string
---@return wonderland.StyleBuilder
local function segmentShape(theme, width, height, inset, fill)
	return sty():w(width):h(height - inset * 2):radius(theme:radius("full")):align("center"):justify("center"):bg(fill)
end

--- One choice of several, as a pill split into options: the chosen one is filled in the accent.
--- Returns the element and its width.
---@param app beat.App
---@param props beat.components.SegmentedProps
---@return wonderland.Element
---@return number
function settingsList.segmented(app, props)
	local theme = app.services.appearance.theme
	local height = props.height or theme:px(32)
	local inset = theme:px(3)
	-- What the pill is drawn from depends on its options and which of them is chosen, not on the
	-- frame: the options table and a bit per choice key the record, and both are numbers or a
	-- table an option list already is, so asking again makes nothing.
	local byHeight = styles.of(theme, "settingsSegment", props.width or 0) --[[@as table<number, table<table, table<number, table>>>]]
	local byOptions = byHeight[height]
	if byOptions == nil then
		byOptions = {}
		byHeight[height] = byOptions
	end
	local byChoice = byOptions[props.options]
	if byChoice == nil then
		byChoice = {}
		byOptions[props.options] = byChoice
	end
	local mask = 0
	for at = 1, #props.options do
		if props.options[at].selected then mask += 2 ^ (at - 1) end
	end
	local kept = byChoice[mask] --[[@as { widths: number[]?, total: number?, box: wonderland.StyleBuilder?, cells: table[]? }]]
	if kept == nil then
		kept = {}
		byChoice[mask] = kept
	end
	if kept.box == nil or kept.cells == nil then
		local labelStyle = theme:s():text(theme:type("sm")):weight("semibold")
		local widths = {}
		local total = inset * 2
		if props.width ~= nil then
			local each = math.floor((props.width - inset * 2) / #props.options)
			for at = 1, #props.options do widths[at] = each end
			total = props.width
		else
			for at, option in ipairs(props.options) do
				widths[at] = math.max(
					theme:px(56),
					math.ceil(measure.width(app, option.label, labelStyle) or theme:px(40)) + theme:px(24)
				)
				total += widths[at]
			end
		end

		local cells = {}
		for at, option in ipairs(props.options) do
			local chosen = option.selected
			cells[at] = {
				base = segmentShape(theme, widths[at], height, inset, chosen and theme:color("accent") or "#00000000"),
				hover = segmentShape(theme, widths[at], height, inset, chosen and theme:color("accent") or theme:color("hover")),
				text = theme:s():text(theme:type("sm")):weight("semibold"):fg(chosen and theme.accentInk or theme:color("muted"))
			}
		end

		kept.widths, kept.total, kept.cells = widths, total, cells
		kept.box = sty()
			:row():w(total):h(height):pad(inset):radius(theme:radius("full")):align("center")
			:bg(theme:color("bg")):border(theme:px(1), theme:color("border"))
	end

	local cells = assert(kept.cells)
	local pill = div():style(kept.box --[[@as wonderland.StyleBuilder]])
	for at, option in ipairs(props.options) do
		local cell = assert(cells[at])
		pill:children(
			div()
				:style(cell.base)
				:hover(cell.hover)
				:onClick(option.message)
				:children(text(option.label):style(cell.text))
		)
	end

	return pill, kept.total --[[@as number]]
end

---@class beat.components.ToggleProps
---@field on boolean
---@field onClick any # What flipping it sends

--- An on/off switch: a knob in a track, the track filled in the accent when on. Returns the
--- element and its width.
---@param app beat.App
---@param props beat.components.ToggleProps
---@return wonderland.Element
---@return number
function settingsList.toggle(app, props)
	local theme = app.services.appearance.theme
	local on = props.on == true
	local kept = styles.of(theme, "settingsToggle", on and 1 or 0) --[[@as { track: wonderland.StyleBuilder?, knob: wonderland.StyleBuilder?, width: number }]]
	if kept.track == nil or kept.knob == nil then
		local width, height = theme:px(44), theme:px(26)
		local knob = height - theme:px(6)
		local travel = width - knob - theme:px(6)
		kept.width = width
		kept.track = sty()
			:w(width):h(height):radius(theme:radius("full")):pad(theme:px(3))
			:bg(on and theme:color("accent") or theme:color("active"))
		kept.knob = sty()
			:size(knob, knob):radius(theme:radius("full")):offset(on and travel or 0, 0)
			:bg(on and theme.accentInk or theme:color("muted"))
	end
	return div():style(assert(kept.track)):onClick(props.onClick):children(div():style(assert(kept.knob))), kept.width
end

--- A small outlined label, such as "Core" or a version. Returns the element and its width.
---@param app beat.App
---@param label string
---@return wonderland.Element
---@return number
function settingsList.badge(app, label)
	local theme = app.services.appearance.theme
	local kept = styles.of(theme, "settingsBadge", label) --[[@as { box: wonderland.StyleBuilder?, text: wonderland.StyleBuilder?, width: number? }]]
	if kept.box == nil or kept.text == nil then
		local style = theme:s():text(theme:type("xs")):weight("semibold")
		local width = math.ceil(measure.width(app, label, style) or theme:px(24)) + theme:px(16)
		local height = theme:px(20)
		kept.width = width
		kept.box = sty()
			:w(width):h(height):radius(theme:radius("full")):align("center"):justify("center")
			:border(theme:px(1), theme:color("border"))
		kept.text = theme:s():text(theme:type("xs")):weight("semibold"):fg(theme:color("faint"))
	end
	return div():style(assert(kept.box)):children(text(label):style(assert(kept.text))), assert(kept.width)
end

return settingsList
