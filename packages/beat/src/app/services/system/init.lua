-- Asking the desktop to open a URL, or the plugins folder in the file manager. It is not a page's
-- business how a browser or a file manager is found there, and several very different screens want
-- it: the About links and Last.fm's authorization page, and the plugins page. They also want the
-- same answer when nothing could be opened, so the failure is a toast here rather than a second
-- copy of the platform command in each caller.
local fs = require("fs")
local paths = require("beat.paths")
local links = require("beat.app.services.system.links")

---@class beat.SystemService: beat.Service
---@field toasts beat.ToastsService
local System = {}
System.__index = System
System.needs = { "toasts" }

---@param deps { toasts: beat.ToastsService }
---@return beat.SystemService
function System.new(deps)
	return setmetatable({ toasts = deps.toasts }, System)
end

--- Open a URL and say whether it worked. The opener reports failure by returning false, and the
--- command behind it can be missing altogether, which throws; either way the caller is told the
--- link did not open.
---@param url string
---@return boolean
function System:open(url)
	local ok, opened = pcall(links.open, url)
	return ok and opened ~= false
end

System.on = {
	--- A link button. The settings screen and the Last.fm card both send this, so the one handler
	--- says what a link failing looks like.
	---@param self beat.SystemService
	---@param message beat.OpenURLMessage
	openURL = function(self, message)
		if not self:open(message.url) then
			self.toasts:show("Could not open the link", "error")
		end
	end,

	---@param self beat.SystemService
	---@param _message beat.OpenPluginsFolderMessage
	openPluginsFolder = function(self, _message)
		-- The folder is made first: the page's control is also how a person finds out where
		-- plugins go, and an empty folder is the useful answer when there are none yet.
		local folder = paths.file("plugins")
		fs.mkdirAll(folder)
		if not self:openFolder(folder) then
			self.toasts:show("Could not open the plugins folder", "error")
		end
	end
}

--- Open a folder and say whether it worked, the same way `open` does for a URL.
---@param dir string
---@return boolean
function System:openFolder(dir)
	local ok, opened = pcall(links.openFolder, dir)
	return ok and opened ~= false
end

return System
