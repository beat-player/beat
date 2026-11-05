local test = require("lde-test")
local wonderland = require("wonderland")
local Atlas = require("wonderland.font.atlas")
local face = require("beat-ui.icons-font")

test.it("carries the icon face as a module and draws a glyph from its bytes", function()
	test.equal(face:sub(1, 4), "\0\1\0\0", "the module is a TrueType face")

	local name = wonderland.embedFont("beat.test.icons", face)
	local atlas = assert(Atlas.fromBytes({ pixelHeight = 16 }, face))
	local glyph = atlas:glyph(0xE000)

	test.equal(name, "beat.test.icons", "the face is named for a style to ask for")
	test.greater(glyph.width, 0, "a glyph is packed from the embedded bytes")
end)
