-- The page that lists plugins and switches outside ones off. It is built in, like settings: the
-- app's plugin list is what it shows, so it cannot be one of the outside plugins that disappear
-- when a bundle fails to load.
local pluginsPage = require("beat.app.pages.plugins")

return {
	name = "plugins",
	version = "1.0.0",
	setup = function(beat)
		beat.page("plugins", pluginsPage)
	end,
}
