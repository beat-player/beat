-- Last.fm scrobbling, which watches playback rather than being part of it.
local beat = require("beat")
local lastfm = require("beat.app.services.lastfm")

return beat.plugin({
	name = "lastfm",
	version = "1.0.0",
	requires = { core = "^1.0.0", playback = "^1.0.0" },
	setup = function(handle)
		handle.service("lastfm", lastfm)
	end,
})
