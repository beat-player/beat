-- Editing tags: an "Edit metadata" entry on the track and album menus, the dialog it opens, and
-- the service that writes the changes into the files.
local beat = require("beat")
local metadata = require("beat.app.services.metadata")
local editor = require("beat.app.overlays.metadata_editor")

return beat.plugin({ name = "metadata", version = "1.0.0", author = "beat", description = "Editing the tags in your files", requires = { core = "^1.0.0", library = "^1.0.0", playback = "^1.0.0", tasks = "^1.0.0" }, setup = function(handle)
	handle.service("metadata", metadata)
	handle.overlay("metadata_editor", editor)
	handle.action({ menu = "album", title = "Edit metadata", icon = "edit", order = 60, message = |ctx| -> { type = "open", overlay = "metadata_editor", kind = "album", id = assert(ctx.album).id } })
	handle.action({ menu = "track", title = "Edit metadata", icon = "edit", order = 60, message = |ctx| -> { type = "open", overlay = "metadata_editor", kind = "track", id = assert(ctx.track).id } })
end })
