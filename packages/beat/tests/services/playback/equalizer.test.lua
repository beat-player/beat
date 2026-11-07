local test = require("lde-test")
local equalizer = require("beat.app.services.playback.equalizer")

test.it("ships five named bands and a flat default", function()
	test.equal(#equalizer.frequencies, 5)
	test.equal(#equalizer.labels, 5)
	test.equal(equalizer.presetGains("flat")[1], 0)
	test.equal(#equalizer.bands(equalizer.presetGains("club")), 5)
end)

test.it("sanitises missing, extreme and unknown gains", function()
	local gains = equalizer.sanitize({ 99, -99, 0, 0, 3})
	test.equal(gains[1], 12)
	test.equal(gains[2], -12)
	test.equal(gains[5], 3)
	test.equal(equalizer.sanitize({})[4], 0, "a missing gain is flat")
end)

test.it("turns gains into the bands the audio player expects", function()
	local bands = equalizer.bands({ 4, -2, 0, 7, 1})
	test.equal(bands[1].frequency, 60)
	test.equal(bands[1].gain, 4)
	test.equal(bands[5].frequency, 14000)
	test.equal(bands[5].gain, 1)
end)

test.it("gives every preset the same gain count and a unique id", function()
	---@type table<string, boolean>
	local seen = {}
	for _, item in ipairs(equalizer.presets) do
			local preset = item --[[@as beat.EqualizerPreset]]
			local id = preset.id
			test.equal(#preset.gains, 5)
			test.falsy(seen[id], "preset ids are unique")
			seen[id] = true
		end
	test.truthy(seen["speaker"])
	test.truthy(seen["lowBass"])
	test.truthy(seen["highBass"])
end)
