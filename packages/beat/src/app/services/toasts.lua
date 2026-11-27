-- The messages that slide in over the top right corner: a failure and what it was about, or what
-- just happened. They are the app's only channel for saying something without taking the screen,
-- so the list lives here and the view above every other frame reads it. A toast under the pointer
-- is kept alive by the pointer moving over it: the view sends a hold message from the toast's own
-- mouse handler, and the service pushes that toast's expiry forward from there. The service needs
-- no ticks between animations and expiries.
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
---@field heldAt number? # When a move over it last held it, for the throttle below
---@field holdMessage beat.ToastHoldMessage? # The view's one message per toast, reused on every move
---@field holdHandler (fun(): beat.ToastHoldMessage)? # And the handler that answers a move with it

---@class beat.ToastHoldMessage
---@field type "toastHold"
---@field at number # The toast's `at`, which is what names it to the view and back

-- How often a move over a toast may push its expiry. A pointer moving over one sends a message
-- per motion event; five a second is enough to keep it alive, and a clock field on the toast
-- keeps the check from allocating anything.
local HOLD_RECHECK = 0.2

---@class beat.ToastsService: beat.Service
---@field list beat.Toast[]
local Toasts = {}
Toasts.__index = Toasts

---@return beat.ToastsService
function Toasts.new()
	return setmetatable({ list = {} }, Toasts)
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
	end,
	--- The pointer moved over a toast. A pointer that is moving is a pointer whose person is
	--- looking at it, so the toast gets its full life again; moves arrive faster than that is
	--- worth doing, so one within `HOLD_RECHECK` of the last is ignored.
	---@param self beat.ToastsService
	---@param message beat.ToastHoldMessage
	toastHold = function(self, message)
		local now = time.now()
		for at = 1, #self.list do
			local toast = self.list[at]
			if toast.at == message.at then
				local heldAt = toast.heldAt
				if heldAt == nil or now - heldAt >= HOLD_RECHECK then
					toast.heldAt = now
					toast.expires = now + (toast.tone == "error" and ERROR_LIFE or LIFE)
				end
				return
			end
		end
	end
}

-- The slide in and the fade out are the only moments a toast moves. Between them it is a line of
-- text sitting still, so the ticker wakes at the next of them instead of every frame. A hold is
-- what a pointer over one asks for, and no timer is needed to notice it: the move itself is the
-- message.
local SLIDE = 0.18
local FADE = 0.3

function Toasts:step(now)
	local list = self.list
	local count = #list
	if count == 0 then return false, false end

	local changed = false
	local animating = false
	local nextAt = math.huge
	local kept = 1

	for at = 1, count do
		local toast = list[at]
		local life = toast.tone == "error" and ERROR_LIFE or LIFE
		local expires = toast.expires or (toast.at + life)
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
	-- Still toasts only need the clock for the moment their fade begins.
	return changed, nextAt
end

return Toasts
