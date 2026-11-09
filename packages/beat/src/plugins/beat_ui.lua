-- The beat-ui package as a built-in plugin. It registers nothing: it exists so that an outside
-- plugin can say `requires = { ["beat-ui"] = "^0.1.0" }` and have the loader compare that against
-- the version of the UI API the app actually ships. A version that does not fit is reported and
-- the plugin is left out, like any other plugin requirement.
local beatUi = require("beat-ui")

return {
	name = "beat-ui",
	version = beatUi.version,
	---@param _handle beat.PluginHandle
	setup = function(_handle) end
}
