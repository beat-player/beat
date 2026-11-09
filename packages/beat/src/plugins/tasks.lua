-- The task list: what long-running work the app is doing, shown from the top bar. The service is
-- shared, so a plugin's own service lists `needs = { "tasks" }` and reports into the same panel
-- the app's work uses.
local beat = require("beat")
local tasks = require("beat.app.services.tasks")
local tasksPanel = require("beat.app.overlays.tasks")

return beat.plugin({ name = "tasks", version = "1.0.0", setup = function(handle)
	handle.service("tasks", tasks)
	handle.overlay("tasks", tasksPanel)
end })
