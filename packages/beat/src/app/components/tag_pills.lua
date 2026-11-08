-- Tag pills laid out in fixed columns. `action` is a function from a tag to the message its pill
-- sends, or nil for a read-only pill.
local wonderland = require("wonderland")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local tagPills = {}

---@class beat.components.TagPillsProps
---@field tags beat.Tag[]
---@field selected table<number, boolean>? # Tag ids drawn as selected
---@field action (fun(tag: beat.Tag): any)? # The message a pill sends; omitted, the pills are read-only
---@field width number # The room the columns share
---@field columns number
---@field limit number? # Show at most this many, then a count of the rest

---@param app beat.App
---@param props beat.components.TagPillsProps
---@return wonderland.Element?
function tagPills.view(app, props)
	local tags, selected, action = props.tags, props.selected, props.action
	local width, columns, limit = props.width, props.columns, props.limit
	if #tags == 0 then return nil end
	local theme = app.services.appearance.theme
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
		:bg(active ? (theme:color("accent")) : (theme:color("elevated")))
		:border((theme:px(1)), active ? (theme:color("accent")) : (theme:color("border"))))
		:children(text(tag.name):style(theme:s():w(pillWidth - theme:px(20)):text(theme:type("xs"))
		:weight("semibold"):fg(fg):ellipsis()))
		if action ~= nil then pill:onClick(action(tag)) end
		row[#row + 1] = pill
		shown += 1
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
	if limit ~= nil and #tags > limit then height += theme:px(18) end
	return div():style(sty():column():wrel(1.0):h(height):gap(theme:px(8))):children(rows)
end

return tagPills
