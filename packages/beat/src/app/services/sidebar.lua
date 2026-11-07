-- The playlist a sidebar row is pointing at. The tooltip is a frame's hit test answering -- the
-- row says which playlist and where it is, and the chrome over the page draws the name -- so the
-- answer belongs to the sidebar and not to the page underneath. It lives only while the pointer
-- is still: any other message means the pointer left the row or something was pressed, and the
-- frame built for it must not keep the old label.
local Signal = require("beat.app.signal")

---@class beat.SidebarHover
---@field id number
---@field y number
---@field top number?
---@field x number?
---@field height number?

---@class beat.SidebarService
---@field hover beat.SidebarHover?
---@field collections beat.CollectionsService
local Sidebar = {}
Sidebar.__index = Sidebar
Sidebar.needs = { "collections", "messages" }
Sidebar.handles = { "hoverPlaylist" }

---@param deps { collections: beat.CollectionsService, messages: beat.Signal }
---@return beat.SidebarService
function Sidebar.new(deps)
	local self = setmetatable({ hover = nil, collections = deps.collections }, Sidebar)
	-- Messages are fired as they are delivered, before anything acts on them, so a hover left
	-- behind by the last frame is gone before the frame that replaces it is built.
	deps.messages:connect(function(message)
		if message.type ~= "hoverPlaylist" then self.hover = nil end
	end)
	return self
end

-- A frame's hit test answering, not a screen deciding what to draw: the row reports the slot it
-- found and the service keeps it only when that is a playlist that still exists.
function Sidebar:update(message)
	local id = tonumber(message.id)
	local playlist = id ~= nil and self.collections.taxonomy:playlist(id) or nil
	if playlist == nil then
		self.hover = nil
		return
	end

	local y = tonumber(message.y) or 0
	local top = tonumber(message.top)
	local x = tonumber(message.x)
	local height = tonumber(message.height)
	local old = self.hover
	if old == nil or old.id ~= id or old.y ~= y or old.top ~= top
	or old.x ~= x or old.height ~= height then
		self.hover = {
			id = id --[[@as number]], y = y, top = top, x = x, height = height,
		}
	end
end

return Sidebar
