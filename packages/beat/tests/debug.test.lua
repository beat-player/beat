-- The performance overlay's numbers, without a window: the ring the frames go into, the second it
-- is read over, and the two lines the overlay shows.
local test = require("lde-test")
local Debug = require("beat.app.services.debug.stats")

test.it("counts the frames that went out in the last second", function()
	local window = Debug.Window.new(1, 16)
	window:record(10.0, 4)
	window:record(10.2, 8)
	window:record(10.4, 2)

	local summary = window:summary(10.5)
	test.equal(summary.frames, 3)
	test.equal(summary.average, 14 / 3)
	test.equal(summary.max, 8)

	-- The frame at 10.0 is now more than a second old; the ones after it are not.
	window:record(11.1, 16)
	summary = window:summary(11.1)
	test.equal(summary.frames, 3)
	test.equal(summary.average, 26 / 3)
	test.equal(summary.max, 16)
end)

test.it("says idle when the window has emptied", function()
	local window = Debug.Window.new(1, 16)
	window:record(10.0, 4)
	test.equal(window:summary(10.999).frames, 1, "the frame is still inside the second")
	test.equal(window:summary(11.0).frames, 0, "and is out at exactly one second, which is idle")
	test.equal(window:summary(12.2).frames, 0)
	test.equal(window:summary(12.2).average, 0)
	test.equal(window:summary(12.2).max, 0)
end)

test.it("keeps the newest frames when the ring fills", function()
	local window = Debug.Window.new(10, 3)
	window:record(1, 10)
	window:record(2, 20)
	window:record(3, 30)
	window:record(4, 40)

	local summary = window:summary(4.5)
	test.equal(summary.frames, 3, "the oldest sample made room for the newest")
	test.equal(summary.average, 30)
	test.equal(summary.max, 40)
end)

test.it("asks for one frame when the screen goes idle and then leaves it alone", function()
	local Service = require("beat.app.services.debug")
	local service = Service.new({ app = {} })
	service.lastFrameAt = 10

	test.equal(service:step(11), true, "the second without a frame is drawn once to say idle")
	test.equal(service:step(11.5), nil, "and the overlay does not keep the screen awake")
	test.equal(service:step(12), nil, "not even at the next second")

	-- A real frame is what starts the next wait: `presented` is what a frame goes through.
	service.lastFrameAt = 15
	service.idleShown = false
	test.equal(service:step(16), true, "the next quiet second is drawn once too")
end)

test.it("formats the rate, the frame times and the memory", function()
	test.equal(
		Debug.format({ frames = 60, average = 8.34, max = 21.0 }, 44 * 1024, 180 * 1024),
		"60 fps  avg 8.3 ms  max 21.0 ms\nlua 44.0 MB  rss 180 MB"
	)
	test.equal(
		Debug.format({ frames = 60, average = 8.34, max = 21.0 }, 44 * 1024, nil),
		"60 fps  avg 8.3 ms  max 21.0 ms\nlua 44.0 MB",
		"a platform without /proc leaves the resident size out"
	)
	test.equal(
		Debug.format({ frames = 0, average = 0, max = 0 }, 44 * 1024, 180 * 1024),
		"idle\nlua 44.0 MB  rss 180 MB"
	)
end)
