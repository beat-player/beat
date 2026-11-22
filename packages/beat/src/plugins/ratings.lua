-- Ratings: the stars on a track and on an album. The plugin registers nothing of its own; the
-- screens that can set a rating ask `app.registry:hasPlugin("ratings")` before drawing their stars,
-- so switching it off takes every star out of the app while the rating data Collections keeps is
-- left where it is for when the plugin comes back.
local beat = require("beat")

return beat.plugin({
	name = "ratings",
	version = "1.0.0",
	author = "beat",
	description = "Stars on tracks and albums",
	---@param _handle beat.PluginHandle
	setup = function(_handle) end
})
