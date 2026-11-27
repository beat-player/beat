-- The update dialog's progress bar, without a window: what it reads from the service, how wide
-- the fill is at the ends and the middle, and when it slides instead. The view itself is a canvas
-- so these are the numbers that decide what it paints.
local test = require("lde-test")
local overlay = require("beat.app.overlays.update")

local MEGABYTE = 1024 * 1024

test.it("reads the download's fraction and bytes from the service", function()
	local state = overlay.barState({
		status = "downloading",
		progress = 0.42,
		progressReceived = 12.6 * MEGABYTE,
		progressTotal = 30 * MEGABYTE
	})

	test.equal(state.fraction, 0.42)
	test.equal(state.received, 12.6 * MEGABYTE)
	test.equal(state.total, 30 * MEGABYTE)
	test.falsy(state.indeterminate)
end)

test.it("fills 0, half and all of the track at 0, 50 and 100 percent", function()
	test.equal(overlay.fillWidth(0, 340), 0)
	test.equal(overlay.fillWidth(0.5, 340), 170)
	test.equal(overlay.fillWidth(1, 340), 340)
	-- A value past either end is clamped rather than drawn outside the track.
	test.equal(overlay.fillWidth(-0.2, 340), 0)
	test.equal(overlay.fillWidth(1.5, 340), 340)
	-- Whole pixels only, so the same fraction paints the same rectangle.
	test.equal(overlay.fillWidth(0.42, 341), 143)
end)

test.it("slides only while the total is unknown", function()
	local unknown = overlay.barState({ status = "downloading", progress = nil })
	test.truthy(unknown.indeterminate)
	test.equal(unknown.fraction, nil)

	-- Before the first progress event a known total still draws a determinate, empty track.
	local known = overlay.barState({ status = "downloading", progress = nil, progressTotal = 100 })
	test.falsy(known.indeterminate)

	-- Any other state has no bar to move, even with the numbers left over.
	test.falsy(overlay.barState({ status = "ready" }).indeterminate)
	test.falsy(overlay.barState({ status = "available" }).indeterminate)
end)

test.it("writes the transfer as megabytes when both ends are known", function()
	test.equal(overlay.bytesText(12.3 * MEGABYTE, 30 * MEGABYTE), "12.3 of 30.0 MB")
	test.equal(overlay.bytesText(0, 4 * MEGABYTE), "0.0 of 4.0 MB")
	test.equal(overlay.bytesText(nil, 10 * MEGABYTE), nil)
	test.equal(overlay.bytesText(10, nil), nil)
	test.equal(overlay.bytesText(10, 0), nil)
end)
