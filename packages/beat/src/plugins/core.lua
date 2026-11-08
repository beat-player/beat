-- The app before it is anything in particular: what it remembers, how it moves, what it looks
-- like, what it says and how it reaches the desktop. The menu panel is here too, because every
-- feature draws its context menu with the same one.
local beat = require("beat")
local settings = require("beat.app.services.settings")
local motion = require("beat.app.services.motion")
local appearance = require("beat.app.services.appearance")
local toasts = require("beat.app.services.toasts")
local scroll = require("beat.app.services.scroll")
local system = require("beat.app.services.system")

local settingsPage = require("beat.app.pages.settings")
local accentPicker = require("beat.app.overlays.accent_picker")
local menu = require("beat.app.overlays.menu")

return beat.plugin({
	name = "core",
	version = "1.0.0",
	setup = function(handle)
		handle.service("settings", settings)
		handle.service("motion", motion)
		handle.service("appearance", appearance)
		handle.service("toasts", toasts)
		handle.service("scroll", scroll)
		handle.service("system", system)

		handle.page("settings", settingsPage)
		handle.overlay("accent_picker", accentPicker)
		handle.overlay("menu", menu)
	end,
})
