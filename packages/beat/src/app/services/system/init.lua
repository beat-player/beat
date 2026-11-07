-- Asking the desktop to open a URL. It is not a page's business how a browser is found there, and
-- two very different screens want it: the About links in settings and Last.fm's authorization
-- page. Both also want the same answer when there is no browser to open, so the failure is a toast
-- here rather than a second copy of the platform command in each caller.
local links = require("beat.app.services.system.links")

---@class beat.SystemService
---@field toasts beat.ToastsService
local System = {}
System.__index = System
System.needs = { "toasts" }
System.handles = { "openURL" }

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

--- A link button. The settings screen and the Last.fm card both send this, so the one handler
--- says what a link failing looks like.
---@param message table
function System:update(message)
	if message.type == "openURL" then
		if not self:open(message.url) then
			self.toasts:show("Could not open the link", "error")
		end
	end
end

return System
