-- The press marks: what keeps the app awake while a ripple is growing, and puts it back to sleep
-- when the last one is gone. The marks themselves are beat-ui's -- a press starts one and a draw
-- shows it -- so this service is only the clock side of them, the same way the motion service is the
-- clock side of the page slide.
--
-- It also carries the two things the marks need from the app's settings rather than from a view:
-- whether motion is reduced, which turns the growing circle into a box lit for a moment, and where
-- the app is showing, because a mark that was drawn in a place the app has left is one nobody
-- pressed.
local ripple = require("beat-ui.ripple")

---@class beat.RippleService: beat.ServiceInstance
---@field settings beat.SettingsService
---@field app beat.App
---@field page any # The page the marks were last cleared against
---@field overlay any # And the top overlay, so opening or closing one clears the marks drawn under it
---@field seen number # The marks' generation the last frame was built for
local Ripple = {}
Ripple.__index = Ripple
Ripple.needs = { "settings", "app" }

---@param deps { settings: beat.SettingsService, app: beat.App }
---@return beat.RippleService
function Ripple.new(deps)
	ripple.reduced = deps.settings.values.reduceMotion == true

	return setmetatable({
		settings = deps.settings,
		app = deps.app,
		page = nil,
		overlay = nil,
		seen = ripple.generation
	}, Ripple)
end

--- The ripples of the screen the app has left are not this screen's: they were drawn where a
--- control was, and another control is there now. A component that gave its press a key of its own
--- keeps it -- that key says the control is still the one that was pressed -- and the ones held by
--- their place in the screen go.
---@param self beat.RippleService
local function clearLeftBehind(self)
	local app = self.app
	local page = app.page
	local overlays = app.overlays
	local overlay = overlays ~= nil and overlays[#overlays] or nil

	if self.page ~= nil and (page ~= self.page or overlay ~= self.overlay) then
		ripple.clearVolatile()
	end

	self.page, self.overlay = page, overlay
end

---@param now number
---@return boolean? changed
---@return boolean? busy
---@return boolean? repaint
function Ripple:step(now)
	ripple.reduced = self.settings.values.reduceMotion == true
	clearLeftBehind(self)

	local active, ended = ripple.advance(now)
	local generation = ripple.generation
	local built = generation ~= self.seen
	self.seen = generation

	if active > 0 then
		-- A mark that has just started or restarted needs the screen built again, because the draw
		-- that shows it is attached on that frame; the frames between are the same screen with the
		-- mark drawn again, which is a repaint rather than a solve.
		if built or ended then return true, true end
		return false, true, true
	end
	if built or ended then return true, false end
	return nil, nil
end

--- The app is being set up again, and the controls the marks were kept by are not there any more.
function Ripple:close()
	ripple.reset()
end

return Ripple
