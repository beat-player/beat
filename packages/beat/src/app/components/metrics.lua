-- The sizes the screen is cut into: the phone breakpoint, the gutters, the shell's bars and the
-- room a page has between them. Pure functions of the app's theme, settings and the window.
local metrics = {}

--- The phone breakpoint. The 960×640 desktop still uses the icon rail; a phone gets the bottom
--- navigation and a full-width page.
---@param app beat.App
---@param width number
---@return boolean
function metrics.mobile(app, width)
	return width < app.services.appearance.theme:px(760)
end

---@param app beat.App
---@param width number?
---@return number
function metrics.pad(app, width)
	if width ~= nil and metrics.mobile(app, width) then return app.services.appearance.theme:space(16) end
	return app.services.appearance.theme:space(32)
end

---@param app beat.App
---@param width number
---@return number
function metrics.sidebarWidth(app, width)
	if metrics.mobile(app, width) then return 0 end
	if app.services.settings.values.sidebarCollapsed or width < 1040 then return app.services.appearance.theme:px(76) end
	return app.services.appearance.theme:px(app.services.settings.values.sidebarWidth)
end

--- The room a page has inside the body: the shell, both paddings, and the scroll bar's strip.
---@param app beat.App
---@param width number
---@return number
function metrics.contentWidth(app, width)
	return width - metrics.sidebarWidth(app, width) - metrics.pad(app, width) * 2 - app.services.appearance.theme:px(8)
end

---@param app beat.App
---@param width number
---@return number
function metrics.topbarHeight(app, width)
	return app.services.appearance.theme:px(metrics.mobile(app, width) and 56 or 64)
end

---@param app beat.App
---@param width number
---@return number
function metrics.bottomHeight(app, width)
	local theme = app.services.appearance.theme
	if metrics.mobile(app, width) then
		local player = app.services.playback:current() ~= nil and theme:px(64) or 0
		return player + theme:px(58)
	end
	return app.services.playback:current() ~= nil and theme:px(88) or 0
end

---@param app beat.App
---@param width number
---@param height number
---@return number
function metrics.viewportHeight(app, width, height)
	return height - metrics.topbarHeight(app, width) - metrics.bottomHeight(app, width)
end

--- The same 1–5 column ladder for every album shelf. It is driven by the content box, because
--- the sidebar and the mobile bottom bars are not part of the width a grid can use.
---@param content number
---@return number
function metrics.gridColumns(content)
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
function metrics.panelWidth(app, window, max)
	local gutter = app.services.appearance.theme:space(metrics.mobile(app, window.width) and 16 or 24)
	return math.min(app.services.appearance.theme:px(max), window.width - gutter * 2)
end

return metrics
