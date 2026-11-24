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
local haptics = require("beat.app.services.system.haptics")
local http = require("beat.app.services.http")
local update = require("beat.app.services.update")

-- Pages and overlays are named by module, not read here: one is read when it is first shown.
local settingsPage = "beat.app.pages.settings"
local accentPicker = "beat.app.overlays.accent_picker"
local menu = "beat.app.overlays.menu"
local mobileMenu = "beat.app.overlays.mobile_menu"
local confirmLeave = "beat.app.overlays.confirm_leave"
local updateDialog = "beat.app.overlays.update"

return beat.plugin({ name = "core", version = "1.0.0", author = "beat", description = "Settings, appearance and the app's own screens", setup = function(handle)
	handle.service("settings", settings)
	handle.service("motion", motion)
	handle.service("appearance", appearance)
	handle.service("toasts", toasts)
	handle.service("scroll", scroll)
	handle.service("system", system)
	handle.service("haptics", haptics)
	handle.service("http", http)
	handle.service("update", update)

	handle.page("settings", settingsPage)
	handle.overlay("accent_picker", accentPicker)
	handle.overlay("menu", menu)
	handle.overlay("mobile_menu", mobileMenu)
	handle.overlay("confirm_leave", confirmLeave)
	handle.overlay("update", updateDialog)
end })
