local test = require("lde-test")
local equalizer = require("beat.app.services.equalizer.bands")

test.it("ships five named bands and a flat default", function()
	test.equal(#equalizer.frequencies, 5)
	test.equal(#equalizer.labels, 5)
	test.equal(equalizer.presetGains("flat")[1], 0)
	test.equal(#equalizer.bands(equalizer.presetGains("club")), 5)
end)

test.it("sanitises missing, extreme and unknown gains", function()
	local gains = equalizer.sanitize({ 99, -99, 0, 0, 3 })
	test.equal(gains[1], 12)
	test.equal(gains[2], -12)
	test.equal(gains[5], 3)
	test.equal(equalizer.sanitize({})[4], 0, "a missing gain is flat")
end)

test.it("turns gains into the bands the audio player expects", function()
	local bands = equalizer.bands({ 4, -2, 0, 7, 1 })
	test.equal(bands[1].frequency, 60)
	test.equal(bands[1].gain, 4)
	test.equal(bands[5].frequency, 14000)
	test.equal(bands[5].gain, 1)
end)

test.it("gives every preset the same gain count and a unique id", function()
	---@type table<string, boolean>
	local seen = {}
	for _, preset in ipairs(equalizer.presets) do
		local id = preset.id
		test.equal(#preset.gains, 5)
		test.falsy(seen[id], "preset ids are unique")
		seen[id] = true
	end
	test.truthy(seen["speaker"])
	test.truthy(seen["lowBass"])
	test.truthy(seen["highBass"])
end)

test.it("combines the faders, the profile's filters and the preamp", function()
	local profile = {
		name = "Profile",
		preamp = -3,
		filters = {
			{ type = "peak", frequency = 105, gain = -2.3, q = 0.7 },
			{ type = "lowpass", frequency = 18000, gain = 0, q = 0.707 }
		}
	}
	local bank = equalizer.combine({ 1, 2, 3, 4, 5 }, 2, profile)
	test.equal(#bank, 7)
	test.equal(bank[1].type, "peak")
	test.equal(bank[1].gain, 1)
	test.equal(bank[6].frequency, 105)
	test.equal(bank[6].type, "peak")
	test.equal(bank[7].type, "lowpass")
	test.equal(bank.preamp, -1, "the fader's 2 dB and the profile's -3 dB")

	test.equal(equalizer.combine({}, 99, nil).preamp, 6, "the fader is held to its own range")
	test.equal(equalizer.combine({}, 0, { preamp = 12, filters = {} }).preamp, 12)
	test.equal(equalizer.combine({}, 6, { preamp = 12, filters = {} }).preamp, 12, "the sum is held to the player's")
end)

test.it("draws the summed response, not a curve through the fader gains", function()
	local points = equalizer.curvePoints
	test.equal(#equalizer.response(equalizer.combine({}, 0, nil)), points)

	-- A +6 dB peaking band at 1 kHz: the response at 1 kHz is 6 dB, and the preamp shifts the
	-- whole curve down by its own amount.
	local bank = equalizer.combine({}, 0, nil)
	bank[#bank + 1] = { type = "peak", frequency = 1000, gain = 6, q = 1.4 }
	local preamp = equalizer.combine({}, 0, nil)
	preamp[#preamp + 1] = { type = "peak", frequency = 1000, gain = 6, q = 1.4 }
	preamp.preamp = -6

	local curve = equalizer.response(bank)
	local shifted = equalizer.response(preamp)
	local at = 1 + math.floor(equalizer.curveFraction(1000) * (points - 1) + 0.5)
	-- The samples are a little either side of 1 kHz; a Q of 1.4 keeps the peak broad.
	test.truthy(curve[at] > 5.5 and curve[at] < 6.5, "the curve peaks near the band's +6 dB")
	test.truthy(math.abs(shifted[at] - (curve[at] - 6)) < 0.01, "the preamp shifts the whole response")

	-- A low pass falls away above its corner and leaves the low end alone.
	local pass = equalizer.combine({}, 0, { name = "Pass", preamp = 0, filters = { { type = "lowpass", frequency = 1000, gain = 0, q = 0.707 } } })
	local passCurve = equalizer.response(pass)
	test.truthy(passCurve[1] > -1 and passCurve[1] < 1, "20 Hz is in the passband")
	test.truthy(passCurve[points] < -20, "20 kHz is far down the stopband")
end)
