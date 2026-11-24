-- The page that lists beat's own plugins and the outside ones, and switches off the optional ones.
-- It is built in, like settings: the app's plugin list is what it shows, so it cannot be one of the
-- outside plugins that disappear when a bundle fails to load.
local pluginsPage = "beat.app.pages.plugins"

return {
	name = "plugins",
	version = "1.0.0",
	author = "beat",
	description = "The plugins page and its switches",
	---@param handle beat.PluginHandle
	setup = function(handle)
		handle.page("plugins", pluginsPage)
	end
}
