-- A toast is a line of text that sits still between its slide and its fade: the ticker should only
-- come back for those two moments, and a pointer moving over one is what keeps it there. These
-- tests drive the service's own clock and hold message without a window.
local test = require("lde-test")
local time = require("wonderland.time")
local Toasts = require("beat.app.services.toasts")

test.it("wakes at a still toast's fade, not four times a second", function()
	local toasts = Toasts.new()
	toasts:show("still here")
	local toast = toasts.list[1]
	toast.at, toast.expires = 0, 10

	local changed, busy = toasts:step(1)
	test.falsy(changed)
	test.greater(busy, 8, "the next wake is the fade's start, not a pointer poll")
	test.less(busy, 9)
end)

test.it("holds a toast when the pointer moves over it", function()
	local toasts = Toasts.new()
	toasts:show("held")
	local toast = toasts.list[1]
	toast.at, toast.expires = 0, 5

	toasts.on.toastHold(toasts, { type = "toastHold", at = 0 })
	local held = toast.expires
	test.greater(held, time.now() + 4, "a move gives the toast its life again")

	toast.expires = 5
	toasts.on.toastHold(toasts, { type = "toastHold", at = 0 })
	test.equal(toast.expires, 5, "a second move within the throttle is ignored")

	toast.heldAt = time.now() - 1
	toasts.on.toastHold(toasts, { type = "toastHold", at = 0 })
	test.greater(toast.expires, 5, "a later move holds it again")
end)
