-- One beat per config directory: a second claim is refused while the first holds it, a launch
-- that finds it held hands over and is heard exactly once, and a released claim is free again.
-- The claims are the operating system's own objects, so each test names a directory of its own.
local test = require("lde-test")
local instance = require("beat.instance")

local used = 0
local function directory()
	used = used + 1
	return os.tmpname() .. "-beat-instance-" .. used
end

test.it("a second claim on a directory is refused while the first holds it", function()
	local place = directory()
	local first = assert(instance.claim(place))

	local second, err = instance.claim(place)
	test.equal(second, nil)
	test.equal(err, "running")

	local elsewhere = instance.claim(directory())
	test.truthy(elsewhere ~= nil, "another config directory is another beat")

	first:release()
	assert(elsewhere):release()
end)

test.it("a released claim can be made again", function()
	local place = directory()
	assert(instance.claim(place)):release()

	local again = instance.claim(place)
	test.truthy(again ~= nil, "nothing is left holding it")
	assert(again):release()
end)

test.it("a launch that finds the directory held hands over, and is heard once", function()
	local place = directory()
	local running = assert(instance.claim(place))
	test.equal(running:poll(), false, "nobody has asked yet")

	local handedOver, claim = instance.start(place)
	test.equal(handedOver, true, "the launch ends")
	test.equal(claim, nil)
	test.equal(running:poll(), true, "the running copy hears it")
	test.equal(running:poll(), false, "and only once")

	running:release()
end)

test.it("a launch with nothing running is the one that runs", function()
	local place = directory()
	local handedOver, claim, err = instance.start(place)
	test.equal(handedOver, false)
	test.equal(err, nil)
	test.truthy(claim ~= nil, "it holds the claim")

	local _, why = instance.claim(place)
	test.equal(why, "running", "and a later launch finds it")
	assert(claim):release()
end)
