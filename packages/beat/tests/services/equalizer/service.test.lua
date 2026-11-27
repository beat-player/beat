local test = require("lde-test")
local fs = require("fs")
local json = require("json")
local paths = require("beat.paths")
local settingsModel = require("beat.app.services.settings.model")
local Equalizer = require("beat.app.services.equalizer")
local Player = require("beat.app.services.playback.player")
local Spectrum = require("beat.app.services.playback.spectrum")

--- What a hand-edited settings file may hold for the equalizer: any preset name, and gains or
--- saved presets that are not what the panel would write.
---@class beat.EqualizerFileFixture
---@field equalizerPreset string?
---@field equalizerGains (number|string|nil)[]?
---@field equalizerCustomPresets { name: string, gains: (number|string|nil)[] }[]?
---@field equalizerPreamp any
---@field equalizerProfile any

--- The service over a settings file holding `data`, with stand-ins that record what it asks them
--- to do. The rules that read and rewrite what the file held are what these tests are about; the
--- panel and the player are only where the result shows.
---@param data beat.EqualizerFileFixture
local function start(data)
	local dir = os.tmpname() .. "-beat-equalizer"
	fs.mkdirAll(dir)
	fs.write(paths.file("settings.json", dir), json.encode(data))

	---@type beat.SettingsService
	local settings = { values = settingsModel.load(dir), changed = function() end }
	---@type treble.Equalizer.Band[][]
	local applied = {}
	local player = Player.new()
	function player.setEqualizer(_, bands) applied[#applied + 1] = bands end
	---@type beat.PlaybackService
	local playback = {
		player = player,
		spectrum = Spectrum.new(),
		settings = settings,
		toasts = { list = {}, show = function() end },
		emit = function() end,
		library = {},
		collections = {},
		sessionKey = ""
	}
	---@class EqualizerToastsStub: beat.ToastsService
	---@field shown { text: string, tone: string? }[]
	---@type EqualizerToastsStub
	local toasts = { list = {}, shown = {} }
	function toasts:show(text, tone) self.shown[#self.shown + 1] = { text = text, tone = tone } end
	local emitted = {}

	local equalizer = Equalizer.new(
		{
			settings = settings,
			playback = playback,
			toasts = toasts,
			emit = function(message) emitted[#emitted + 1] = message end,
			window = function() return nil end
		}
	)
	return equalizer, settings, toasts, emitted, applied, dir
end

local function finish(dir)
	fs.delete(paths.file("settings.json", dir))
	fs.rmdir(dir)
end

test.it("cleans up the equalizer settings it is started with", function()
	local _, settings, _, _, applied, dir = start({ equalizerPreset = "Missing", equalizerGains = { 99, -99, 0 }, equalizerCustomPresets = { { name = "Low Bass", gains = { 1, 1, 1, 1, 1 } }, { name = "Mine", gains = { 40, 0, 0, 0, 0 } }, { name = "Mine", gains = { 0 } }, { name = "", gains = { 0 } }, { name = "Two", gains = { "quiet", 1, nil, 2 } } } })
	local values = settings.values
	local gains = assert(values.equalizerGains)
	local presets = assert(values.equalizerCustomPresets)

	test.equal(values.equalizerPreset, "custom", "a preset that is gone keeps the gains that were stored")
	test.equal(gains[1], 12, "and every gain is held to the range")
	test.equal(gains[2], -12)
	test.equal(gains[5], 0, "a missing gain is flat")

	test.equal(#presets, 2, "a built-in name and a duplicate are dropped")
	test.equal(presets[1].name, "Mine", "the first of a repeated name is the one kept")
	test.equal(presets[1].gains[1], 12, "a saved preset's gains are held too")
	test.equal(presets[2].gains[1], 0, "a gain that is not a number is flat")
	test.equal(presets[2].gains[4], 2)

	test.equal(applied[1][1].gain, 12, "the player is told the bands when the service starts")
	test.equal(#applied[1], 5)

	finish(dir)
end)

test.it("falls back to the saved custom preset's gains, then to Flat", function()
	local _, settings, _, _, applied, dir = start({ equalizerPreset = "Mine", equalizerCustomPresets = { { name = "Mine", gains = { 3, 2, 1, 0, -1 } } } })

	local mineGains = assert(settings.values.equalizerGains)
	test.equal(settings.values.equalizerPreset, "Mine")
	test.equal(mineGains[1], 3, "a custom preset without stored gains holds its own")
	test.equal(applied[1][5].gain, -1)
	finish(dir)

	local _, flat, _, _, flatApplied, flatDir = start({ equalizerPreset = "Gone" })
	local flatGains = assert(flat.values.equalizerGains)
	local flatPresets = assert(flat.values.equalizerCustomPresets)
	test.equal(flat.values.equalizerPreset, "flat", "nothing to fall back to is Flat")
	test.equal(flatGains[1], 0)
	test.equal(#flatPresets, 0)
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

test.it("keeps the panel's preset list between frames and follows a saved preset", function()
	local equalizer, _, _, _, _, dir = start({})
	local bands = require("beat.app.services.equalizer.bands")
	local builtins = #bands.presets

	local first = equalizer:presets()
	test.equal(#first, builtins)
	test.equal(equalizer:presets(), first, "the list is kept while nothing changes")
	test.equal(equalizer:find("flat"), first[1], "a lookup reads the kept list")

	equalizer:create()
	local list = equalizer:presets()
	test.equal(#list, builtins + 1, "a saved preset joins the list")
	test.notEqual(list, first, "and the list is rebuilt once")

	local custom = list[#list]
	test.equal(custom.name, "Custom")
	equalizer:rename("Custom", "Warm")
	equalizer:presets()
	test.equal(custom.name, "Warm", "a rename is read through the kept wrapper")
	equalizer:setGain(1, 4)
	equalizer:presets()
	test.equal(custom.gains[1], 4, "an edited preset's gains are read through it")

	equalizer:delete("Warm")
	test.equal(#equalizer:presets(), builtins, "a deleted preset leaves the list")
	finish(dir)
end)

-- The sample a person would copy from AutoEq's page: one OFF filter that must not play, a low
-- shelf, a high shelf and a peaking band.
local SAMPLE_PROFILE = [[
Preamp: -6.1 dB
Filter 1: ON PK Fc 105 Hz Gain -2.3 dB Q 0.70
Filter 2: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.71
Filter 3: ON HSC Fc 10000 Hz Gain -3.0 dB Q 0.71
Filter 4: OFF PK Fc 2000 Hz Gain 1.0 dB Q 1.41
]]

test.it("puts the imported profile's filters under the faders and adds both preamps", function()
	local profile = {
		name = "HD 650",
		preamp = -6,
		filters = {
			{ type = "peak", frequency = 100, gain = 4, q = 1.2 },
			{ type = "lowpass", frequency = 16000, gain = 0, q = 0.707 }
		}
	}
	local equalizer, settings, _, _, applied, dir = start({ equalizerPreamp = 99, equalizerProfile = profile })
	local bank = applied[1]

	test.equal(#bank, 7, "five faders and the profile's two filters")
	test.equal(bank[1].frequency, 60)
	test.equal(bank[1].type, "peak", "the faders are peaking bands")
	test.equal(bank[6].frequency, 100)
	test.equal(bank[6].type, "peak")
	test.equal(bank[7].type, "lowpass")
	test.equal(bank.preamp, 0, "the fader is held to +6 and the profile asks for -6")
	test.equal(settings.values.equalizerPreamp, 6, "the stored fader is held to its own range")
	test.equal(equalizer:profile().name, "HD 650")
	test.equal(#equalizer:curve(), 96, "the curve is sampled when the bank is made")

	finish(dir)
end)

test.it("holds the summed preamp to what the audio player takes", function()
	local equalizer, settings, _, _, applied, dir = start({
		equalizerProfile = { name = "Loud", preamp = 12, filters = { { type = "peak", frequency = 1000, gain = 1, q = 1 } } }
	})
	equalizer.on.equalizerPreamp(equalizer, { type = "equalizerPreamp", value = 25 })
	test.equal(settings.values.equalizerPreamp, 6, "the fader stops at its top")
	test.equal(applied[#applied].preamp, 12, "6 + 12 is held to the player's ceiling")
	test.equal(settings.values.equalizerPreset, "flat", "a preamp is not a preset")

	finish(dir)
end)

test.it("imports pasted text under a name and clears back to the five bands", function()
	local equalizer, settings, _, _, applied, dir = start({})
	local before = #applied

	equalizer.on.equalizerImportText(equalizer, { type = "equalizerImportText", text = SAMPLE_PROFILE })
	local profile = assert(settings.values.equalizerProfile)
	test.equal(profile.name, "Pasted profile")
	test.equal(profile.preamp, -6.1)
	test.equal(#profile.filters, 3, "the OFF filter is dropped")
	test.equal(profile.filters[1].type, "peak")
	test.equal(profile.filters[2].type, "lowshelf")
	test.equal(profile.filters[3].type, "highshelf")

	local bank = assert(applied[before + 1])
	test.equal(#bank, 8, "five faders and three filters")
	test.equal(bank[6].frequency, 105)
	test.equal(bank[8].frequency, 10000)
	test.equal(bank.preamp, -6.1)

	equalizer:clearProfile()
	test.falsy(settings.values.equalizerProfile)
	local cleared = assert(applied[#applied])
	test.equal(#cleared, 5, "clearing restores the five faders")
	test.equal(cleared.preamp, 0)

	finish(dir)
end)

test.it("refuses empty or unreadable profile text with a toast", function()
	local equalizer, settings, toasts, _, _, dir = start({})

	equalizer.on.equalizerImportText(equalizer, { type = "equalizerImportText", text = "   " })
	test.falsy(settings.values.equalizerProfile)
	test.equal(toasts.shown[1].text, "The clipboard has no profile text")
	test.equal(toasts.shown[1].tone, "error")

	equalizer.on.equalizerImportText(equalizer, { type = "equalizerImportText", text = "not a profile at all" })
	test.falsy(settings.values.equalizerProfile)
	test.equal(toasts.shown[2].text, "That does not look like an EqualizerAPO profile")

	finish(dir)
end)

test.it("reads a picked profile file and names it after the file", function()
	local equalizer, settings, _, _, applied, dir = start({})
	local folder = os.tmpname() .. "-beat-profile"
	fs.mkdirAll(folder)
	local profileFile = folder .. "/Sennheiser HD 650.txt"
	assert(fs.write(profileFile, SAMPLE_PROFILE))
	local result = os.tmpname() .. "-beat-pick"
	assert(fs.write(result, profileFile .. "\n"))

	equalizer.pick = { file = result, platform = "test", kind = "file" }
	test.truthy(equalizer:step(0), "the answer is a change")
	local profile = assert(settings.values.equalizerProfile)
	test.equal(profile.name, "Sennheiser HD 650", "the extension is not part of the name")
	test.equal(#applied[#applied], 8)

	fs.delete(profileFile)
	fs.rmdir(folder)
	finish(dir)
end)

test.it("says so when no system file dialog exists", function()
	local equalizer, settings, toasts, _, _, dir = start({})
	local result = os.tmpname() .. "-beat-pick"
	assert(fs.write(result, "__NO_PICKER__"))

	equalizer.pick = { file = result, platform = "test", kind = "file" }
	test.truthy(equalizer:step(0))
	test.falsy(settings.values.equalizerProfile)
	test.equal(toasts.shown[1].text, "No system file dialog is available on this machine")

	finish(dir)
end)

test.it("polls an open profile dialog at a quarter second", function()
	local equalizer, _, _, _, _, dir = start({})
	equalizer.pick = { file = os.tmpname() .. "-beat-profile-pending", platform = "test", kind = "file" }

	local changed, busy = equalizer:step(0)
	test.falsy(changed)
	test.equal(busy, 0.25, "the open dialog is checked, not drawn for")
	finish(dir)
end)
