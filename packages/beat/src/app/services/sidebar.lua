-- The playlist a sidebar row is pointing at. The tooltip is a frame's hit test answering -- the
-- row says which playlist and where it is, and the chrome over the page draws the name -- so the
-- answer belongs to the sidebar and not to the page underneath. It lives only while the pointer
-- is still: any other message means the pointer left the row or something was pressed, and the
-- frame built for it must not keep the old label.

---@class beat.SidebarHover
---@field id number
---@field y number
---@field top number?
---@field x number?
---@field height number?

-- The rail opening and closing: the width the shell cuts the content box by. A transition is a
-- number the frame draws from, so it lives on the motion clock and the one ticker that moves all
-- of them keeps the screen coming while it runs.
local WIDTH_KEY = "sidebarWidth"
local WIDTH_TIME = 0.19
-- The width is read by styles, and a style is interned by its values: a dozen steps per
-- transition is a dozen styles, where one per frame is the arena growing with every toggle.
local WIDTH_STEPS = 12

---@class beat.SidebarService: beat.Service
---@field hover beat.SidebarHover?
---@field collections beat.CollectionsService
---@field motion beat.MotionService
---@field collapsed boolean? # Which form the rail was last asked for, to know when it is opening
local Sidebar = {}
Sidebar.__index = Sidebar
Sidebar.needs = { "collections", "messages", "motion" }

---@param deps { collections: beat.CollectionsService, messages: beat.Signal, motion: beat.MotionService }
---@return beat.SidebarService
function Sidebar.new(deps)
	local self = setmetatable({ hover = nil, collections = deps.collections, motion = deps.motion }, Sidebar)
	-- Messages are fired as they are delivered, before anything acts on them, so a hover left
	-- behind by the last frame is gone before the frame that replaces it is built.
	deps.messages:connect(function(message)
		if message.type ~= "hoverPlaylist" then self.hover = nil end
	end)
	return self
end

--- A frame's hit test answering, not a screen deciding what to draw: the row reports the slot it
--- found and the service keeps it only when that is a playlist that still exists.
---@param self beat.SidebarService
---@param message beat.HoverPlaylistMessage
local function applyHover(self, message)
	local id = tonumber(message.id)
	local playlist = id ~= nil ? (self.collections.taxonomy:playlist(id)) : nil
	if playlist == nil then
		self.hover = nil
		return
	end

	local y = tonumber(message.y) or 0
	local top = tonumber(message.top)
	local x = tonumber(message.x)
	local height = tonumber(message.height)
	local old = self.hover
	if old == nil or old.id ~= id or old.y ~= y or old.top ~= top or old.x ~= x or old.height ~= height then
		self.hover = {
			id = id, --[[@as number]]
			y = y,
			top = top,
			x = x,
			height = height
		}
	end
end

---@param value number
---@return number
local function wholePixel(value)
	return math.floor(value + 0.5)
end

--- How wide the rail is at `now`, read from the transition it is in: stepped to a dozen widths,
--- so a frame asks the style cache for one of a handful of builders rather than a new one.
---@param known beat.MotionValue
---@param now number
---@return number
local function widthAt(known, now)
	if known.duration <= 0 or now >= known.start + known.duration then return known.to end
	local t = (now - known.start) / known.duration
	if t < 0 then t = 0 elseif t > 1 then t = 1 end
	local step = math.floor(known.easing(t) * WIDTH_STEPS + 0.5)
	return wholePixel(known.from + (known.to - known.from) * step / WIDTH_STEPS)
end

--- The rail's width this frame. A change of form -- the toggle, or the window crossing the width
--- breakpoint -- eases from wherever the rail is now; the grip's own width changes are set
--- directly, because a rail that trails the pointer reads as broken rather than smooth.
---@param self beat.SidebarService
---@param target number
---@param collapsed boolean # Whether the rail is headed for its narrow form
---@param now number
---@return number
function Sidebar:width(target, collapsed, now)
	target = wholePixel(target)
	local clock = self.motion.clock
	local known = clock.values[WIDTH_KEY]
	local changed = self.collapsed ~= nil and self.collapsed ~= collapsed
	self.collapsed = collapsed

	if known == nil or clock.reduce then
		clock:update(now)
		known = clock.values[WIDTH_KEY]
		if known == nil or known.to ~= target or known.duration > 0 then clock:set(WIDTH_KEY, target) end
		return target
	end

	if changed then
		-- The clock sleeps between animations, and the width on the screen is the stepped one,
		-- not the clock's exact value: the transition starts from what was drawn last.
		local from = widthAt(known, now)
		clock:update(now)
		clock:animate(WIDTH_KEY, target, WIDTH_TIME, self.motion.ease.outCubic)
		known = clock.values[WIDTH_KEY]
		known.from, known.value = from, from
		return widthAt(known, now)
	end

	local active = known.duration > 0 and now < known.start + known.duration
	if active and known.to == target then return widthAt(known, now) end

	-- Not a form transition: the grip was dragged, or a settled rail's target moved. There is
	-- nothing to ease -- a rail trailing the pointer reads as broken rather than smooth.
	if known.to ~= target or known.duration > 0 then
		clock:update(now)
		clock:set(WIDTH_KEY, target)
	end
	return target
end

Sidebar.on = {
	---@param self beat.SidebarService
	---@param message beat.HoverPlaylistMessage
	hoverPlaylist = function(self, message) applyHover(self, message) end
}

return Sidebar
