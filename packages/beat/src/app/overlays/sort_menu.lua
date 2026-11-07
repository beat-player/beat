-- The sort choices, anchored under the library's sort button.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local metrics = require("beat.app.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local SORT_OPTIONS = {
{ key = "title", label = "Title"},
{ key = "artist", label = "Artist"},
{ key = "year", label = "Year"},
{ key = "recent", label = "Recently added"},
{ key = "modified", label = "File last modified"},
}

---@type beat.OverlaySurface
local sortMenu = { light = true}

function sortMenu.new(app, params)
	return {}
end

function sortMenu.update(app, overlay, message)
	if message.type == "sort" then
		app.settings.sort = message.value or "title"
		app.sortedAlbums = nil
		app:markSettingsDirty()
		app:close(overlay)
		return true
	end
	return false
end

function sortMenu.view(app, overlay, window)
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
	:onClick({ type = "keep"})
	:children(rows)

	return div()
	:style(sty():fill():offset(0, 0):z(70):column():align("end")
	:pad(theme:px(window.width < 560 and 156 or 138), metrics.pad(app), 0, 0))
	:onClick({ type = "dismiss"})
	:children({ panel})
end

return sortMenu
