local test = require("lde-test")
local autoeq = require("beat.app.services.equalizer.autoeq")

local SAMPLE = [[
Preamp: -6.1 dB
Filter 1: ON PK Fc 105 Hz Gain -2.3 dB Q 0.70
Filter 2: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.71
Filter 3: ON HSC Fc 10000 Hz Gain -3.0 dB Q 0.71
Filter 4: OFF PK Fc 2000 Hz Gain 1.0 dB Q 1.41
]]

test.it("reads the profile AutoEq writes", function()
	local profile = assert(autoeq.parse(SAMPLE))
	test.equal(profile.preamp, -6.1)
	test.equal(#profile.filters, 3, "the OFF filter is not played")

	local first = profile.filters[1]
	test.equal(first.type, "peak")
	test.equal(first.frequency, 105)
	test.equal(first.gain, -2.3)
	test.equal(first.q, 0.7)
	test.equal(profile.filters[2].type, "lowshelf")
	test.equal(profile.filters[2].gain, 5.5)
	test.equal(profile.filters[3].type, "highshelf")
	test.equal(profile.filters[3].frequency, 10000)
end)

test.it("takes CRLF, extra spaces, comments and the other type names", function()
	local text = table.concat({
		"# exported by AutoEq",
		"Preamp: -3.5 dB",
		"Filter 1:   ON   LS   Fc 80 Hz Gain 4 dB Q 0.9",
		"Filter 2: ON HS Fc 12000 Hz Gain -2 dB Q 0.7   ",
		"Filter 3: ON LP Fc 18000 Hz",
		"Filter 4: ON HP Fc 30 Hz",
		""
	}, "\r\n")
	local profile = assert(autoeq.parse(text))
	test.equal(profile.preamp, -3.5)
	test.equal(#profile.filters, 4)
	test.equal(profile.filters[1].type, "lowshelf")
	test.equal(profile.filters[2].type, "highshelf")
	test.equal(profile.filters[3].type, "lowpass")
	test.equal(profile.filters[3].gain, 0, "a pass has no gain")
	test.equal(profile.filters[3].q, 0.707, "a pass without Q takes the Butterworth value")
	test.equal(profile.filters[4].type, "highpass")
	test.equal(profile.filters[4].frequency, 30)
end)

test.it("ignores lines and filters it cannot play", function()
	local profile = assert(
		autoeq.parse(
			table.concat({
				"Preamp: 0 dB",
				"Filter 1: ON PEAKING Fc 100 Hz Gain 2 dB Q 1",
				"Filter 2: ON PK Fc 0 Hz Gain 2 dB Q 1",
				"Filter 3: OFF LSC Fc 100 Hz Gain 2 dB Q 1",
				"Filter 4: ON XX Fc 100 Hz Gain 2 dB Q 1",
				"Filter 5: ON LPQ Fc 900 Hz Gain -1 dB Q 0.6",
				"Some comments from a person who edited it by hand.",
				"",
			}, "\n")
		)
	)
	test.equal(#profile.filters, 1, "only the low pass is a filter this player can make")
	test.equal(profile.filters[1].type, "lowpass")
	test.equal(profile.filters[1].frequency, 900)
end)

test.it("refuses text with nothing to play", function()
	local profile, err = autoeq.parse("")
	test.falsy(profile)
	test.truthy(err)

	local noise, noiseErr = autoeq.parse("hello\nthis is not a profile")
	test.falsy(noise)
	test.truthy(noiseErr)

	local blank, blankErr = autoeq.parse("   \n\t\n")
	test.falsy(blank)
	test.truthy(blankErr)
end)

test.it("accepts a profile that only corrects the level", function()
	local profile = assert(autoeq.parse("Preamp: -8 dB\n"))
	test.equal(profile.preamp, -8)
	test.equal(#profile.filters, 0, "no filters is a level correction, not a mistake")
	local without = assert(autoeq.parse("Filter 1: ON PK Fc 1000 Hz Gain -2 dB Q 1\n"))
	test.equal(without.preamp, 0, "a file with no preamp line is corrected by nothing")
end)

test.it("holds a stored profile to the ranges the player takes and caps its filters", function()
	local filters = {}
	for at = 1, 24 do
		filters[at] = { type = "PK", frequency = 20 + at, gain = 99, q = 0 }
	end
	filters[#filters + 1] = { type = "peak", frequency = -1, gain = 0, q = 1 }
	local profile = assert(autoeq.sanitize({ name = "  Loud  ", preamp = -99, filters = filters }))
	test.equal(profile.name, "Loud")
	test.equal(profile.preamp, -24)
	test.equal(#profile.filters, autoeq.maximumFilters, "the extras are dropped, not the profile")
	test.equal(profile.filters[1].type, "peak", "the player's own names are read too")
	test.equal(profile.filters[1].gain, 24)
	test.equal(profile.filters[1].q, 1.0, "a missing Q is the shape's default")

	test.falsy(autoeq.sanitize(nil))
	test.falsy(autoeq.sanitize({ name = "", filters = { { type = "PK", frequency = 100 } } }))
	test.falsy(autoeq.sanitize({ name = "Empty" }), "a profile with no bands and no level correction is nothing")
end)
