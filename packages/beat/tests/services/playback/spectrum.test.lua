local test = require("lde-test")
local ffi = require("ffi")
local Spectrum = require("beat.app.services.playback.spectrum")

test.it("puts a sine wave in the upper half of the band strip", function()
	local samples = ffi.new("int16_t[?]", 512)
	local cycles = 64
	for at = 0, 511 do
		samples[at] = math.floor(math.sin(2 * math.pi * cycles * at / 512) * 20000)
	end

	local spectrum = Spectrum.new()
	spectrum:feed(samples, 512, 1)
	test.truthy(spectrum:step(1))

	local levels = spectrum:values()
	local best, bestAt = 0, 0
	for at, value in ipairs(levels) do
		if value > best then best, bestAt = value, at end
	end

	test.truthy(best > 0.3)
	test.truthy(bestAt > 16, "the low half is not the peak")
end)

test.it("decays when nothing new arrives", function()
	local samples = ffi.new("int16_t[?]", 512)
	for at = 0, 511 do samples[at] = 10000 end

	local spectrum = Spectrum.new()
	spectrum:feed(samples, 512, 1)
	test.truthy(spectrum:step(1))
	spectrum:clear()
	for _, value in ipairs(spectrum:values()) do test.equal(value, 0) end
end)
