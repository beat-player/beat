local test = require("lde-test")
local fs = require("fs")
local path = require("path")
local settingsModel = require("beat.app.services.settings.model")

local function tempDir()
	local dir = os.tmpname() .. "-beat-settings"
	fs.mkdirAll(dir)
	assert(fs.isdir(dir))
	return dir
end

test.it("loads defaults when there is no file", function()
	local dir = tempDir()
	local loaded = settingsModel.load(dir)

	test.equal(loaded.theme, "night")
	test.equal(loaded.accent, "lime")
	test.equal(loaded.volume, 0.8)
	test.equal(loaded.uiScale, 1)
	test.falsy(loaded.root)
	test.equal(loaded.lastfmSessionKey, "")
	test.truthy(loaded.lastfmEnabled)
	test.equal(loaded.equalizerPreset, "flat")
	test.equal(#loaded.equalizerGains, 5)
	test.equal(loaded.equalizerGains[1], 0)
	test.equal(#loaded.equalizerCustomPresets, 0)

	fs.rmdir(dir)
end)

test.it("round-trips the settings a launch remembers", function()
	local dir = tempDir()
	local value = settingsModel.load(dir)

	value.root = "/music"
	value.theme = "day"
	value.accent = "violet"
	value.volume = 0.4
	value.isMuted = true
	value.sort = "artist"
	value.sidebarWidth = 300
	value.uiScale = 1.25
	value.reduceMotion = true
	value.lastfmSessionKey = "session"
	value.lastfmUsername = "scrobbler"
	value.lastfmEnabled = false
	value.equalizerPreset = "Custom 2"
	value.equalizerGains = { 5, 3, 0, 2, 4}
	value.equalizerCustomPresets = { { name = "Custom", gains = { 1, 2, 3, 4, 5}},
	{ name = "Custom 2", gains = { 5, 3, 0, 2, 4}}}

	local ok, err = settingsModel.save(value, dir)
	test.truthy(ok, err)

	local again = settingsModel.load(dir)
	test.equal(again.root, "/music")
	test.equal(again.theme, "day")
	test.equal(again.accent, "violet")
	test.equal(again.volume, 0.4)
	test.truthy(again.isMuted)
	test.equal(again.sort, "artist")
	test.equal(again.sidebarWidth, 300)
	test.equal(again.uiScale, 1.25)
	test.truthy(again.reduceMotion)
	test.equal(again.lastfmSessionKey, "session")
	test.equal(again.lastfmUsername, "scrobbler")
	test.equal(again.lastfmEnabled, false)
	test.equal(again.equalizerPreset, "Custom 2")
	test.equal(again.equalizerGains[1], 5)
	test.equal(again.equalizerGains[5], 4)
	test.equal(#again.equalizerCustomPresets, 2)
	test.equal(again.equalizerCustomPresets[1].name, "Custom")
	test.equal(again.equalizerCustomPresets[2].gains[4], 2)

	fs.delete(settingsModel.file(dir))
	fs.rmdir(dir)
end)

test.it("survives a settings file that is not JSON", function()
	local dir = tempDir()
	fs.write(path.join(dir, "settings.json"), "{not json")

	local loaded = settingsModel.load(dir)
	test.equal(loaded.theme, "night", "a broken file is the defaults")

	fs.delete(settingsModel.file(dir))
	fs.rmdir(dir)
end)
