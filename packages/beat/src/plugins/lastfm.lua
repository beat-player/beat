-- Last.fm scrobbling, which watches playback rather than being part of it.
local lastfm = require("beat.app.services.lastfm")

return {
	name = "lastfm",
	version = "1.0.0",
	requires = { core = "^1.0.0", playback = "^1.0.0" },
	---@param beat beat.PluginHandle
	setup = function(beat)
		beat.service("lastfm", lastfm)
	end,
}
