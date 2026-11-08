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
			emit = function(message) emitted[#emitted + 1] = message end
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
