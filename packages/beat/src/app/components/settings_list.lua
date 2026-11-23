-- The grouped list the settings and plugins pages are made of: a small heading over a rounded box
-- of rows, a hairline between each row. A row says what it is on the left -- a label and a line
-- under it -- and holds its control on the right; where the row is too narrow for both side by
-- side, the control goes under the words instead. The controls a row usually holds are here too:
-- a segmented choice, an on/off switch and a small badge.
local wonderland = require("wonderland")
local measure = require("beat.app.components.helpers.measure")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local settingsList = {}

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
	local children = {}
	local boxHeight = 0
	for at, item in ipairs(props.rows) do
		if at > 1 then
			children[#children + 1] = div():style(sty():w(width - theme:px(32)):h(1):bg(theme:color("border")))
			boxHeight += 1
		end
		children[#children + 1] = item.element
		boxHeight += item.height
	end

	local box = div()
		:style(
			sty()
				:column():w(width):h(boxHeight):pad(0, theme:px(16), 0, theme:px(16)):radius(theme:radius("md"))
				:bg(theme:color("surface")):border(theme:px(1), theme:color("border"))
		)
		:children(children)
	if props.title == nil then return box, boxHeight end

	local headingHeight = math.floor(theme:type("sm") * 1.4)
	local gap = theme:px(8)
	local heading = text(props.title)
		:style(theme:s():w(width):h(headingHeight):text(theme:type("sm")):weight("semibold"):fg(theme:color("muted")):ellipsis())
	local height = headingHeight + gap + boxHeight
	return div():style(sty():column():w(width):h(height):gap(gap)):children({ heading, box }), height
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

--- One row. Returns the element and its height.
---@param app beat.App
---@param props beat.components.SettingsRowProps
---@return beat.components.SettingsItem
function settingsList.row(app, props)
	local theme = app.services.appearance.theme
	local inner = props.width - theme:px(32)
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

	local textWidth = stacked and inner or math.max(theme:px(80), inner - (controlWidth > 0 and (controlWidth + gap) or 0))
	local labelColour = props.dim and theme:color("muted") or theme:color("text")
	local descriptionColour = props.dim and theme:color("faint") or theme:color("muted")

	local labelRow
	if props.badge ~= nil then
		local badgeWidth = props.badgeWidth or 0
		local labelStyle = theme:s():text(labelSize):weight("medium")
		local natural = math.ceil(measure.width(app, props.label, labelStyle) or textWidth) + 1
		local labelWidth = math.max(theme:px(24), math.min(natural, textWidth - badgeWidth - theme:px(8)))
		labelRow = div()
			:style(sty():row():w(textWidth):h(labelHeight):gap(theme:px(8)):align("center"))
			:children(
				{
					text(props.label):style(theme:s():w(labelWidth):text(labelSize):weight("medium"):fg(labelColour):ellipsis()),
					props.badge
				}
			)
	else
		labelRow = text(props.label)
			:style(theme:s():w(textWidth):h(labelHeight):text(labelSize):weight("medium"):fg(labelColour):ellipsis())
	end

	local lines = { labelRow }
	if props.description ~= nil then
		lines[#lines + 1] = text(props.description)
			:style(theme:s():w(textWidth):h(descriptionHeight):text(descriptionSize):fg(descriptionColour):ellipsis())
	end
	local words = div():style(sty():column():w(textWidth):h(textHeight):gap(theme:px(2))):children(lines)

	local height, element
	if stacked then
		height = padY * 2 + textHeight + theme:px(10) + controlHeight
		element = div()
			:style(sty():column():w(inner):h(height):pad(padY, 0, padY, 0):gap(theme:px(10)))
			:children({ words, props.control })
	else
		height = padY * 2 + math.max(textHeight, controlHeight)
		local children = { words }
		if props.control ~= nil then children[#children + 1] = props.control end
		element = div()
			:style(sty():row():w(inner):h(height):gap(gap):align("center"):justify("space-between"))
			:children(children)
	end

	if props.onClick ~= nil then
		element = div()
			:style(sty():w(inner):h(height):radius(theme:radius("sm")))
			:hover(sty():w(inner):h(height):radius(theme:radius("sm")):bg(theme:color("hover", 0.5)))
			:onClick(props.onClick)
			:children({ element })
	end
	return { element = element, height = height }
end

---@class beat.components.SettingsOption
---@field label string
---@field message any # What choosing it sends
---@field selected boolean

---@class beat.components.SegmentedProps
---@field options beat.components.SettingsOption[]
---@field width number? # Fill this width, options sharing it equally; default each option's own width
---@field height number? # Default px(32)

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
	local labelStyle = theme:s():text(theme:type("sm")):weight("semibold")
	local widths = {}
	local total = inset * 2
	if props.width ~= nil then
		local each = math.floor((props.width - inset * 2) / #props.options)
		for at = 1, #props.options do widths[at] = each end
		total = props.width
	else
		for at, option in ipairs(props.options) do
			widths[at] = math.max(theme:px(56), math.ceil(measure.width(app, option.label, labelStyle) or theme:px(40)) + theme:px(24))
			total += widths[at]
		end
	end

	local children = {}
	for at, option in ipairs(props.options) do
		local chosen = option.selected
		local function shape(fill)
			return sty():w(widths[at]):h(height - inset * 2):radius(theme:radius("full")):align("center"):justify("center"):bg(fill)
		end
		children[at] = div()
			:style(shape(chosen ? (theme:color("accent")) : "#00000000"))
			:hover(shape(chosen ? (theme:color("accent")) : (theme:color("hover"))))
			:onClick(option.message)
			:children(
				text(option.label)
					:style(
						theme:s():text(theme:type("sm")):weight("semibold")
							:fg(chosen ? (theme.accentInk) : (theme:color("muted")))
					)
			)
	end

	return div()
		:style(
			sty()
				:row():w(total):h(height):pad(inset):radius(theme:radius("full")):align("center")
				:bg(theme:color("bg")):border(theme:px(1), theme:color("border"))
		)
		:children(children), total
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
	local width, height = theme:px(44), theme:px(26)
	local knob = height - theme:px(6)
	local travel = width - knob - theme:px(6)
	return div()
		:style(
			sty()
				:w(width):h(height):radius(theme:radius("full")):pad(theme:px(3))
				:bg(props.on ? (theme:color("accent")) : (theme:color("active")))
		)
		:onClick(props.onClick)
		:children(
			div():style(
				sty()
					:size(knob, knob):radius(theme:radius("full")):offset(props.on and travel or 0, 0)
					:bg(props.on ? (theme.accentInk) : (theme:color("muted")))
			)
		), width
end

--- A small outlined label, such as "Core" or a version. Returns the element and its width.
---@param app beat.App
---@param label string
---@return wonderland.Element
---@return number
function settingsList.badge(app, label)
	local theme = app.services.appearance.theme
	local style = theme:s():text(theme:type("xs")):weight("semibold")
	local width = math.ceil(measure.width(app, label, style) or theme:px(24)) + theme:px(16)
	local height = theme:px(20)
	return div()
		:style(
			sty()
				:w(width):h(height):radius(theme:radius("full")):align("center"):justify("center")
				:border(theme:px(1), theme:color("border"))
		)
		:children(text(label):style(theme:s():text(theme:type("xs")):weight("semibold"):fg(theme:color("faint")))), width
end

return settingsList
