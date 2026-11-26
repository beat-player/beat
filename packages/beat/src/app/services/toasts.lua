-- The messages that slide in over the top right corner: a failure and what it was about, or what
-- just happened. They are the app's only channel for saying something without taking the screen,
-- so the list lives here and the view above every other frame reads it. A toast under the pointer
-- is kept alive by moving its expiry forward each tick, which is why the service needs the pointer
-- and not the window.
local wonderland = require("wonderland")
local Log = require("beat.log")

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

---@class beat.ToastsService: beat.Service
---@field list beat.Toast[]
---@field pointer fun(): { x: number, y: number }?
local Toasts = {}
Toasts.__index = Toasts
Toasts.needs = { "pointer" }

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
		expires = now + (tone == "error" and ERROR_LIFE or LIFE)
	}
	if #self.list > MAX_VISIBLE then table.remove(self.list, 1) end

	if tone == "error" then Log.write("error", text) end
end

Toasts.on = {
	---@param self beat.ToastsService
	---@param message beat.ToastMessage
	toast = function(self, message) self:show(message.text or "", message.tone) end,
	---@param self beat.ToastsService
	---@param message beat.DismissToastMessage
	dismissToast = function(self, message)
		for at = #self.list, 1, -1 do
			if self.list[at].at == message.at then table.remove(self.list, at) end
		end
	end
}

-- The slide in and the fade out are the only moments a toast moves. Between them it is a line of
-- text sitting still, so the ticker wakes at the next of them instead of every frame.
local SLIDE = 0.18
local FADE = 0.3

-- How often a still toast is looked at: the pointer arriving on one is what keeps it there, and a
-- pointer moving does not wake the app's tick -- it only redraws the frame -- so a ticker that slept
-- until the fade began would let the toast go away under the pointer. Four times a second is the
-- pace of a hidden window, not of a frame.
local POINTER_POLL = 0.25

function Toasts:step(now)
	local list = self.list
	local count = #list
	if count == 0 then return false, false end

	local pointer = self.pointer()
	local changed = false
	local animating = false
	local nextAt = math.huge
	local kept = 1

	-- A toast under the pointer stays there. Its box is recorded by the view that drew it, so the
	-- expiry clock can be moved before the next frame removes it; moving the pointer off starts the
	-- full life again rather than resuming a stale countdown.
	for at = 1, count do
		local toast = list[at]
		local life = toast.tone == "error" and ERROR_LIFE or LIFE
		local expires = toast.expires or (toast.at + life)
		local box = toast.rect

		if pointer ~= nil and box ~= nil and pointer.x >= box.x and pointer.x <= box.x + box.width and pointer.y >= box.y and pointer.y <= box.y + box.height then
			expires = now + life
		end

		toast.expires = expires

		if now < expires then
			list[kept] = toast
			kept = kept + 1
			if now - toast.at < SLIDE or expires - now < FADE then
				changed = true
				animating = true
			else
				local start = expires - FADE - now
				if start < nextAt then nextAt = start end
			end
		else
			changed = true
		end
	end
	for at = kept, count do list[at] = nil end

	if animating then return changed, true end
	if kept == 1 then return changed, false end
	-- A toast between its slide and its fade is not moving, but the pointer may come to rest on it
	-- at any moment: look again soon enough for that to be seen before it expires.
	return changed, math.min(nextAt, POINTER_POLL)
end

return Toasts
