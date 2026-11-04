local test = require("lde-test")
local theme = require("beat-ui").theme

test.it("interpolates colours while a theme change is in flight", function()
	local old = theme.new("night", "lime", 1)
	local new = theme.new("day", "violet", 1)
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
	local current = theme.new("night", "lime", 1.25)
	test.equal(current:px(100), 125)
	test.equal(current:space(16), 20)
	test.truthy(current.accentInk ~= current.accentColour)
end)

test.it("accepts a custom accent colour and gives it a readable ink", function()
	local custom = theme.new("night", "#FF7A66", 1)
	test.equal(custom.accent, "#ff7a66")
	test.equal(custom.accentColour, "#ff7a66")
	test.equal(custom.colors.accent, "#ff7a66")
	test.equal(theme.accentColour("#FF7A66"), "#ff7a66")
	test.equal(custom.accentInk, "#f7f7fa", "a mid-dark custom colour takes the light ink")

	local light = theme.new("night", "#ffffff", 1)
	test.equal(light.accentInk, "#0a0c08", "a pale custom colour takes the dark ink")
end)
