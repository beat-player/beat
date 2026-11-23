-- The sizes the screen is cut into: the phone breakpoint, the gutters, the shell's bars and the
-- room a page has between them. Pure functions of the app's theme, settings and the window.
--
-- A frame asks for the same width a dozen times -- the shell, the top bar, the page, each component
-- that sizes itself from the content box -- and the answer only changes when the window, the theme
-- or the rail's own settings do. What is worked out is kept against those, so the arithmetic is
-- done once per window rather than once per question.
local platform = require("beat.platform")

local metrics = {}

--- A length in the theme's own units: what a window `px` wide is at the listener's scale and the
--- screen's density. Breakpoints are written in these, so a phone at 2.6 pixels a point is a
--- phone and not a 1080-wide desktop.
---@param app beat.App
---@param px number
---@return number
function metrics.units(app, px)
	return px / app.services.appearance.theme.scale
end

--- The pixels the system bars cover: the status bar above, the navigation bar below. Nothing is
--- drawn under them but the background.
---@return number top
---@return number bottom
function metrics.insets()
	local screen = platform.screen()
	return screen.top, screen.bottom
end

---@class beat.components.metrics.Sizes
---@field window number?
---@field theme beat.Theme
---@field collapsed boolean?
---@field settingWidth number
---@field mobile boolean
---@field pad number
---@field sidebar number
---@field content number
---@field topbar number # The top bar with the status bar above it
---@field topbarInset number # How much of `topbar` is the status bar

---@type table<beat.App, beat.components.metrics.Sizes>
local sizes = setmetatable({}, { __mode = "k" })

--- What the app's settings and the window come to, worked out when one of them changes: the same
--- width is asked for a dozen times a frame.
---@param app beat.App
---@param width number?
---@return beat.components.metrics.Sizes
local function sizesFor(app, width)
	local values = app.services.settings.values
	local theme = app.services.appearance.theme
	local memo = sizes[app]
	if memo == nil or memo.window ~= width or memo.theme ~= theme or memo.collapsed ~= values.sidebarCollapsed or memo.settingWidth ~= values.sidebarWidth then
		local mobile = width ~= nil and width < theme:px(760)
		local sidebar = 0
		if width ~= nil and not mobile then
			if values.sidebarCollapsed or width < theme:px(1040) then
				sidebar = theme:px(76)
			else
				sidebar = theme:px(values.sidebarWidth)
			end
		end
		local pad = mobile and theme:space(16) or theme:space(32)
		memo = {
			window = width,
			theme = theme,
			collapsed = values.sidebarCollapsed,
			settingWidth = values.sidebarWidth,
			mobile = mobile,
			pad = pad,
			sidebar = sidebar,
			-- The scroll bar is drawn at the body's far edge, which is the padding the page already
			-- leaves: it does not take a strip out of the content beside it.
			content = width ~= nil and (width - sidebar - pad * 2) or 0,
			-- A phone has no top bar: its page begins under the status bar. A desktop keeps the
			-- bar that holds the search field and settings.
			topbar = mobile and (metrics.insets()) or (theme:px(64) + (metrics.insets())),
			topbarInset = (metrics.insets())
		}
		sizes[app] = memo
	end

	return memo --[[@as beat.components.metrics.Sizes]]
end

--- The phone breakpoint. The 960×640 desktop still uses the icon rail; a phone gets the bottom
--- navigation and a full-width page.
---@param app beat.App
---@param width number
---@return boolean
function metrics.mobile(app, width)
	return sizesFor(app, width).mobile
end

---@param app beat.App
---@param width number?
---@return number
function metrics.pad(app, width)
	return sizesFor(app, width).pad
end

---@param app beat.App
---@param width number
---@return number
function metrics.sidebarWidth(app, width)
	return sizesFor(app, width).sidebar
end

--- The room a page has inside the body: the shell and both paddings. The scroll bar sits in that
--- padding rather than taking a strip of the content.
---@param app beat.App
---@param width number
---@return number
function metrics.contentWidth(app, width)
	return sizesFor(app, width).content
end

---@param app beat.App
---@param width number
---@return number
function metrics.topbarHeight(app, width)
	return sizesFor(app, width).topbar
end

--- How much of the top bar's height is the status bar, which its controls sit below.
---@param app beat.App
---@param width number
---@return number
function metrics.topbarInset(app, width)
	return sizesFor(app, width).topbarInset
end

---@param app beat.App
---@param width number
---@return number
function metrics.bottomHeight(app, width)
	local theme = app.services.appearance.theme
	local _, inset = metrics.insets()
	if sizesFor(app, width).mobile then
		local player = (app.services.playback:current()) ~= nil ? (theme:px(64)) : 0
		return player + theme:px(58) + inset
	end
	return ((app.services.playback:current()) ~= nil ? (theme:px(88)) : 0) + inset
end

---@param app beat.App
---@param width number
---@param height number
---@return number
function metrics.viewportHeight(app, width, height)
	return height - metrics.topbarHeight(app, width) - metrics.bottomHeight(app, width)
end

--- How far a page can scroll: its content, the shell's top padding above it and a margin under
--- it, less the room the window gives it between the bars. The margin is what lets the last of
--- the content come to rest above the player bar rather than against it.
---@param app beat.App
---@param window { width: number, height: number }
---@param contentHeight number
---@return number
function metrics.pageScrollLimit(app, window, contentHeight)
	local theme = app.services.appearance.theme
	local room = theme:space(20) + theme:space(32)
	return math.max(0, contentHeight + room - metrics.viewportHeight(app, window.width, window.height))
end

--- The room a page's pinned header takes from the top of its body (see `beat.PageSurface.header`):
--- the header, the page's top margin above it and a gap under it. A page that pins one scrolls in
--- what is left, so its scroll limit is measured against the viewport less this.
---@param app beat.App
---@param height number # The header's own height
---@return number
function metrics.headerBox(app, height)
	local theme = app.services.appearance.theme
	return theme:space(20) + height + theme:space(12)
end

--- The same 1–5 column ladder for every album shelf. It is driven by the content box, because
--- the sidebar and the mobile bottom bars are not part of the width a grid can use, and read in
--- the theme's units, so a dense phone screen gets a phone's two columns.
---@param app beat.App
---@param content number
---@return number
function metrics.gridColumns(app, content)
	local units = metrics.units(app, content)
	if units >= 900 then return 5 end
	if units >= 640 then return 4 end
	if units >= 420 then return 3 end
	if units >= 260 then return 2 end
	return 1
end

--- A floating panel that a phone can still hold: never wider than the window less its gutter.
--- The context's `panelWidth` is the beat-ui copy of this, and views use that.

return metrics
