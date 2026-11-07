local test = require("lde-test")
local fs = require("fs")
local json = require("json")
local paths = require("beat.paths")
local settingsModel = require("beat.app.services.settings.model")
local Equalizer = require("beat.app.services.equalizer")

--- The service over a settings file holding `data`, with stand-ins that record what it asks them
--- to do. The rules that read and rewrite what the file held are what these tests are about; the
--- panel and the player are only where the result shows.
local function start(data)
	local dir = os.tmpname() .. "-beat-equalizer"
	fs.mkdirAll(dir)
	fs.write(paths.file("settings.json", dir), json.encode(data))

	local settings = { values = settingsModel.load(dir), changed = function() end }
	local applied = {}
	local playback = {
		player = {
			setEqualizer = function(_, bands) applied[#applied + 1] = bands end,
		},
	}
	local toasts = {
		shown = {},
	}
	function toasts:show(text, tone) self.shown[#self.shown + 1] = { text = text, tone = tone } end
	local emitted = {}

	local equalizer = Equalizer.new({
		settings = settings,
		playback = playback,
		toasts = toasts,
		emit = function(message) emitted[#emitted + 1] = message end,
	})
	return equalizer, settings, toasts, emitted, applied, dir
end

local function finish(dir)
	fs.delete(paths.file("settings.json", dir))
	fs.rmdir(dir)
end

test.it("cleans up the equalizer settings it is started with", function()
	local equalizer, settings, _, _, applied, dir = start({
		equalizerPreset = "Missing",
		equalizerGains = { 99, -99, 0},
		equalizerCustomPresets = {
			{ name = "Low Bass", gains = { 1, 1, 1, 1, 1}},
			{ name = "Mine", gains = { 40, 0, 0, 0, 0}},
			{ name = "Mine", gains = { 0}},
			{ name = "", gains = { 0}},
			{ name = "Two", gains = { "quiet", 1, nil, 2}},
		},
	})
	local values = settings.values

	test.equal(values.equalizerPreset, "custom", "a preset that is gone keeps the gains that were stored")
	test.equal(values.equalizerGains[1], 12, "and every gain is held to the range")
	test.equal(values.equalizerGains[2], -12)
	test.equal(values.equalizerGains[5], 0, "a missing gain is flat")

	test.equal(#values.equalizerCustomPresets, 2, "a built-in name and a duplicate are dropped")
	test.equal(values.equalizerCustomPresets[1].name, "Mine", "the first of a repeated name is the one kept")
	test.equal(values.equalizerCustomPresets[1].gains[1], 12, "a saved preset's gains are held too")
	test.equal(values.equalizerCustomPresets[2].gains[1], 0, "a gain that is not a number is flat")
	test.equal(values.equalizerCustomPresets[2].gains[4], 2)

	test.equal(applied[1][1].gain, 12, "the player is told the bands when the service starts")
	test.equal(#applied[1], 5)

	finish(dir)
end)

test.it("falls back to the saved custom preset's gains, then to Flat", function()
	local _, settings, _, _, applied, dir = start({
		equalizerPreset = "Mine",
		equalizerCustomPresets = { { name = "Mine", gains = { 3, 2, 1, 0, -1}}},
	})

	test.equal(settings.values.equalizerPreset, "Mine")
	test.equal(settings.values.equalizerGains[1], 3, "a custom preset without stored gains holds its own")
	test.equal(applied[1][5].gain, -1)
	finish(dir)

	local _, flat, _, _, flatApplied, flatDir = start({ equalizerPreset = "Gone"})
	test.equal(flat.values.equalizerPreset, "flat", "nothing to fall back to is Flat")
	test.equal(flat.values.equalizerGains[1], 0)
	test.equal(#flat.values.equalizerCustomPresets, 0)
	test.equal(#flatApplied[1], 5)
	finish(flatDir)
end)

test.it("stops at eight custom presets and refuses a taken name", function()
	local equalizer, settings, toasts, _, _, dir = start({})
	local values = settings.values

	for at = 1, 8 do equalizer:create() end
	test.equal(#values.equalizerCustomPresets, 8)
	test.equal(values.equalizerCustomPresets[8].name, "Custom 8")

	equalizer:create()
	test.equal(#values.equalizerCustomPresets, 8, "the ninth is not made")
	test.equal(toasts.shown[1].text, "That is enough custom presets for now")
	test.equal(toasts.shown[1].tone, "error")

	test.falsy(equalizer:rename("Custom", "Custom 2"), "a name someone already has is refused")
	test.equal(toasts.shown[2].text, "Choose a preset name that is not already used")
	test.falsy(equalizer:rename("Custom", "   "), "an empty name is refused")
	test.equal(toasts.shown[3].text, "Choose a preset name")

	test.truthy(equalizer:rename("Custom", "  Warm  "), "a free name is trimmed and kept")
	test.equal(values.equalizerCustomPresets[1].name, "Warm")

	equalizer:delete("Custom 8")
	test.equal(#values.equalizerCustomPresets, 7)
	test.equal(values.equalizerPreset, "flat", "deleting the selected preset falls back to Flat")
	test.equal(values.equalizerGains[1], 0)

	finish(dir)
end)
