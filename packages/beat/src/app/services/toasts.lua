-- The messages that slide in over the top right corner: a failure and what it was about, or what
-- just happened. They are the app's only channel for saying something without taking the screen,
-- so the list lives here and the view above every other frame reads it. A toast under the pointer
-- is kept alive by moving its expiry forward each tick, which is why the service needs the pointer
-- and not the window.
local wonderland = require("wonderland")
local Log = require("beat.app.log")

local time = wonderland.time

-- An error is the one toast that has to be read whole, so it stays twice as long.
local LIFE = 4.5
local ERROR_LIFE = 8
local MAX_VISIBLE = 3

---@class beat.Toast
---@field text string
---@field tone string
---@field at number
---@field expires number
---@field rect { x: number, y: number, width: number, height: number }? # Where the view last drew it

---@class beat.ToastsService
---@field list beat.Toast[]
---@field pointer fun(): { x: number, y: number }?
local Toasts = {}
Toasts.__index = Toasts
Toasts.needs = { "pointer" }
Toasts.handles = { "toast", "dismissToast" }

---@param deps { pointer: fun(): { x: number, y: number }? }
---@return beat.ToastsService
function Toasts.new(deps)
	return setmetatable({ list = {}, pointer = deps.pointer }, Toasts)
end

---@param text string
---@param tone string?
function Toasts:show(text, tone)
	local now = time.now()
	tone = tone or "info"

	self.list[#self.list + 1] = {
		text = text,
		tone = tone,
		at = now,
		expires = now + (tone == "error" and ERROR_LIFE or LIFE),
	}
	if #self.list > MAX_VISIBLE then table.remove(self.list, 1) end

	if tone == "error" then Log.write("error", text) end
end

function Toasts:update(message)
	if message.type == "toast" then
		self:show(message.text or "", message.tone)
	elseif message.type == "dismissToast" then
		for at = #self.list, 1, -1 do
			if self.list[at].at == message.at then table.remove(self.list, at) end
		end
	end
end

function Toasts:step(now)
	local pointer = self.pointer()
	local kept = {}
	local changed = false

	-- A toast under the pointer stays there. Its box is recorded by the view that drew it, so the
	-- expiry clock can be moved before the next frame removes it; moving the pointer off starts the
	-- full life again rather than resuming a stale countdown.
	for _, toast in ipairs(self.list) do
		local life = toast.tone == "error" and ERROR_LIFE or LIFE
		local expires = toast.expires or (toast.at + life)
		local box = toast.rect

		if pointer ~= nil and box ~= nil and pointer.x >= box.x and pointer.x <= box.x + box.width
		and pointer.y >= box.y and pointer.y <= box.y + box.height then
			expires = now + life
		end

		toast.expires = expires

		if now < expires then
			kept[#kept + 1] = toast
			if now - toast.at < 0.18 or expires - now < 0.3 then changed = true end
		else
			changed = true
		end
	end
	self.list = kept

	return changed, #self.list > 0
end

return Toasts
