-- Performance overlay: the frames the app is actually drawing, what one costs to build and hand
-- to the gpu, and the memory it holds, over the top of every page. It is off on a fresh install
-- and switched on from Settings: the service measures the frames the app draws anyway, so with
-- the plugin off nothing is measured and nothing is drawn.
local beat = require("beat")
local debug = require("beat.app.services.debug")

---@type beat.OverlaySurface
local overlay = {}

function overlay.new()
	return {}
end

---@param app beat.App
---@param _overlay beat.OverlayInstance
---@param window wonderland.RenderWindow
---@return wonderland.Element
function overlay.view(app, _overlay, window)
	return debug.overlay(app, window)
end

return beat.plugin({
	name = "debug",
	version = "1.0.0",
	author = "beat",
	description = "FPS, frame time and memory over the top of the screen",
	setup = function(handle)
		handle.service("debug", debug)
		handle.overlay("debug", overlay)
	end
})
