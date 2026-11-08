-- Everything that makes a sound and every panel that controls it: the player, the queue and the
-- spectrum, the equalizer below them, and the expanded now-playing screen with its own menus.
local beat = require("beat")
local playback = require("beat.app.services.playback")
local equalizer = require("beat.app.services.equalizer")

local nowPlaying = require("beat.app.overlays.now_playing")
local more = require("beat.app.overlays.more")
local volume = require("beat.app.overlays.volume")
local queue = require("beat.app.overlays.queue")
local equalizerPanel = require("beat.app.overlays.equalizer")
local equalizerRename = require("beat.app.overlays.equalizer_rename")

return beat.plugin({ name = "playback", version = "1.0.0", requires = { core = "^1.0.0", library = "^1.0.0", collections = "^1.0.0" }, setup = function(handle)
	handle.service("playback", playback)
	handle.service("equalizer", equalizer)

	handle.overlay("now_playing", nowPlaying)
	handle.overlay("more", more)
	handle.overlay("volume", volume)
	handle.overlay("queue", queue)
	handle.overlay("equalizer", equalizerPanel)
	handle.overlay("equalizer_rename", equalizerRename)
end })
