-- The screens the app shows and the panels it opens over them, found by name rather than listed:
-- a page of kind `searchAll` is `beat.app.pages.search_all`, an overlay named `track_menu` is
-- `beat.app.overlays.track_menu`.
--
-- A page is navigated to and kept in the history with the state it was left in. An overlay is
-- opened over the page, on a stack: a message goes to the overlay on top first, then down the
-- stack, then to the page, then to the app.

---@class beat.PageInstance
---@field kind string
---@field id number?
---@field category string?
---@field state table # What the page keeps while it is showing and while it waits in the history

---@class beat.PageSurface
---@field key (fun(page: beat.PageInstance): string)? # Which page this is, for scroll and for not navigating to itself; the kind when absent
---@field new (fun(app: beat.App, page: beat.PageInstance): table)? # The state a page starts with
---@field update (fun(app: beat.App, page: beat.PageInstance, message: table): boolean?)? # True when the message was this page's
---@field view fun(app: beat.App, page: beat.PageInstance, window: wonderland.RenderWindow): wonderland.Element

---@class beat.OverlayInstance
---@field name string
---@field state table

---@class beat.OverlaySurface
---@field light boolean? # Closes on any message it does not handle itself: menus and popovers. A dialog is not light.
---@field anchored boolean? # Drawn by the screen that opened it, at the button that opened it, rather than by the shell
---@field fullscreen boolean? # Is the screen while it is open: the page and the shell around it are not drawn
---@field new fun(app: beat.App, params: table): table? # The overlay's state, or nil to refuse to open
---@field update (fun(app: beat.App, overlay: beat.OverlayInstance, message: table): boolean?)? # True when the message was this overlay's
---@field view (fun(app: beat.App, overlay: beat.OverlayInstance, window: wonderland.RenderWindow): wonderland.Element?)?
---@field close (fun(app: beat.App, overlay: beat.OverlayInstance))? # What closing it undoes: a focused field, a draft

local surfaces = {}

---@param kind string
---@return string
local function moduleName(kind)
	return (kind:gsub("%u", function(letter) return "_" .. letter:lower() end))
end

--- The page module for a kind.
---@param kind string
---@return beat.PageSurface
function surfaces.page(kind)
	return require("beat.app.pages." .. moduleName(kind))
end

---@param name string
---@return beat.OverlaySurface
function surfaces.overlay(name)
	return require("beat.app.overlays." .. name)
end

return surfaces
