-- The package's public Lua API: what a plugin written outside beat requires. The application's
-- own entry point is `src/main.lua` (lde.json's `bin`), so requiring `beat` gives a plugin the
-- typed constructor below and nothing that opens a window.
local api = {}

-- `beat.PluginModule` is the shape the loader reads; `setup` receives `beat.PluginHandle`, so a
-- plugin writes the handle's name and gets its methods typed without annotating the parameter.
---@class beat.PluginApi
---@field plugin fun(definition: beat.PluginModule): beat.PluginModule

--- The one way to write a plugin: `return require("beat").plugin({ … })`. The value is the
--- definition itself; loading and checking it stays in `beat.app.plugins`, which is where a
--- plugin that does not fit is reported.
---@param definition beat.PluginModule
---@return beat.PluginModule
function api.plugin(definition)
	return definition
end

return api
