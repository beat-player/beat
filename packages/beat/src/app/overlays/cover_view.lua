-- An album's picture on its own, over a dimmed page: the cover is small in the album's header, and
-- a picture that is the point of the page should be readable at more than a thumbnail's size. A
-- click on the picture or the dimness around it closes it; Escape and the phone's back gesture do
-- too, since the app closes the top overlay for either.
local wonderland = require("wonderland")
local cover = require("beat.app.components.cover")

local div, sty = wonderland.div, wonderland.sty

---@class beat.CoverViewState
---@field id number

---@class beat.CoverViewOverlay: beat.OverlaySurface
local coverView = {}

--- The library is read when it opens rather than the page's copy being trusted: the overlay can
--- outlive the scan that made the album, and refuses to open for one that is gone.
---@param params { id: number? }
---@param app beat.App
function coverView.new(app, params)
	local library = app.services.library.current
	local album = nil
	if params.id ~= nil and library ~= nil then album = library:album(params.id) end
	if album == nil then return nil end
	---@type beat.CoverViewState
	return { id = album.id }
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.CoverViewState>
---@param window wonderland.RenderWindow
---@return wonderland.Element?
function coverView.view(app, overlay, window)
	local library = app.services.library.current
	local album = library ~= nil ? (library:album(overlay.state.id)) : nil
	if album == nil then return nil end

	local theme = app.services.appearance.theme
	-- The largest square that leaves a margin on every side. Rounding the side to a step keeps a
	-- window being resized from asking the cover cache for a new side every frame, where each ask
	-- is a decode of its own; the picture is still about as large as fits.
	local step = theme:px(32)
	local side = math.max(step, math.floor(math.min(window.width, window.height) * 0.9 / step) * step)

	return div()
		:style(sty():fill():offset(0, 0):z(124):column():align("center"):justify("center"):bg(theme:color("overlay")))
		:onClick({ type = "dismiss" })
		-- Asking the cover for this side rather than the page's smaller one hands back the scan's
		-- largest cached picture instead of the thumbnail the header was drawn from.
		:children({
			cover.view(app, { album = album, size = side, radius = theme:radius("lg"), glow = true })
				:onClick({ type = "dismiss" })
		})
end

return coverView
