local test = require("lde-test")
local paths = require("beat.paths")
local fs = require("fs")
local Settings = require("beat.app.services.settings")
local Motion = require("beat.app.services.motion")
local Appearance = require("beat.app.services.appearance")

-- Settings reads its values from `paths.directory`; a scratch one keeps the user's own settings
-- out of the way of the themes this test makes.
local configDirectory = os.tmpname() .. "-beat-theme-config"
os.remove(configDirectory)
fs.mkdirAll(configDirectory)

local realDirectory = paths.directory
paths.directory = function() return configDirectory end

test.afterAll(function()
	paths.directory = realDirectory
	fs.rmdir(configDirectory)
end)

--- The real settings and motion services, with the values this test wants to read from them.
---@param theme string
---@param accent string
---@param scale number
local function appearance(theme, accent, scale)
	local settings = Settings.new()
	settings.values.theme = theme
	settings.values.accent = accent
	settings.values.uiScale = scale
	local motion = Motion.new({ settings = settings })
	motion.clock.reduce = false
	return Appearance.new({ settings = settings, motion = motion })
end

test.it("interpolates colours while a theme change is in flight", function()
	local old = appearance("night", "lime", 1).theme
	local new = appearance("day", "violet", 1).theme
	new.fromColors = old.colors
	new.mix = 0.5

	local blended = new:color("bg")
	test.truthy(blended ~= old:color("bg"), "the old colour is not still used")
	test.truthy(blended ~= new.colors.bg, "the target colour is not there yet")
	test.equal(#blended, 9, "a colour is a full RGBA hex string")

	new.mix = 1
	new.fromColors = nil
	test.equal(new:color("bg"):sub(1, 7), new.colors.bg, "the settled theme is exact")
end)

test.it("scales sizes and exposes the accent ink", function()
	local current = appearance("night", "lime", 1.25).theme
	test.equal(current:px(100), 125)
	test.equal(current:space(16), 20)
	test.truthy(current.accentInk ~= current.accentColour)
end)

test.it("accepts a custom accent colour and gives it a readable ink", function()
	local service = appearance("night", "#FF7A66", 1)
	local custom = service.theme
	test.equal(custom.accent, "#ff7a66")
	test.equal(custom.accentColour, "#ff7a66")
	test.equal(custom.colors.accent, "#ff7a66")
	test.equal(service:accentColour("#FF7A66"), "#ff7a66")
	test.equal(custom.accentInk, "#f7f7fa", "a mid-dark custom colour takes the light ink")

	local light = appearance("night", "#ffffff", 1).theme
	test.equal(light.accentInk, "#0a0c08", "a pale custom colour takes the dark ink")
end)
