-- The words a clock becomes: the view beside a playhead asks for one on every frame, so the
-- strings it keeps are keyed by the second they show rather than by the fraction the position
-- happens to be at, and the table they are kept in has a bound.
local test = require("lde-test")
local format = require("beat.app.components.helpers.format")

test.it("keys a clock by the second it shows", function()
	test.equal(format.clock(65.1), "1:05")
	test.equal(format.clock(65.3), "1:05", "the fraction inside a second is the same clock")
	test.equal(format.clock(65.9), "1:06", "and the next second is its own")
	test.equal(format.clock(3600.4), "1:00:00")
	test.equal(format.clock(0), "--:--")
end)

test.it("keeps the clock cache bounded as the playhead moves", function()
	-- A track's worth of playhead fractions: keyed by the fraction, this is thousands of entries
	-- and as many strings, none of which is ever asked for again.
	for at = 1, 4096 do format.clock(100000 + at + 0.25) end
	test.truthy(format.clockCacheSize() <= 512, "the cache has a bound")

	local first = format.clock(200000.1)
	local afterFirst = format.clockCacheSize()
	test.equal(first, "55:33:20")
	test.equal(format.clock(200000.3), first)
	test.truthy(format.clockCacheSize() - afterFirst <= 0, "a second's fractions share one entry")
	test.truthy(afterFirst <= 512, "and it is still bounded")
end)
