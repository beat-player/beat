local test = require("lde-test")
local Bars = require("beat.app.services.system.bars")

-- The decision a phone makes for its status bar icons. It is the same for the navigation bars
-- and for the gesture handle, and it reads the page behind them rather than the theme's name.
test.it("puts dark icons over the day theme", function()
	test.truthy(Bars.isLight("#f6f7f9"), "the day background is near white")
	test.truthy(Bars.isLight("#ffffff"))
end)

test.it("keeps light icons over the night and amoled themes", function()
	test.falsy(Bars.isLight("#0b0c10"), "the night background is near black")
	test.falsy(Bars.isLight("#000000"), "amoled is black")
end)

test.it("reads a crossfaded colour's first six digits", function()
	test.truthy(Bars.isLight("#f6f7f9ff"), "an opaque day colour is still light")
	test.falsy(Bars.isLight("#0b0c10ff"), "an opaque night colour is still dark")
	test.equal(Bars.isLight("#f6f7f980"), Bars.isLight("#f6f7f9"), "the page's alpha does not change the icons")
end)

test.it("treats a colour it cannot read as dark", function()
	test.falsy(Bars.isLight("not a colour"))
end)
