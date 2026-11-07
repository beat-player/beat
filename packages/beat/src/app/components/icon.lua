-- Icons are glyphs from a font built from the Ionicons SVGs under `packages/beat/assets/ionicons`.
-- A font is a vector at every size, is anti-aliased by the same text renderer as the rest of the
-- screen, and takes the theme colour from the element's foreground; the SVG sources are kept
-- beside the generated face so the artwork can be checked or regenerated.
local utf8 = require("utf8")
local wonderland = require("wonderland")

local div, sty = wonderland.div, wonderland.sty

local icon = {}

---@class beat.components.IconProps
---@field name string # A name from the glyph table below
---@field size number # The square the glyph is drawn in
---@field colour string # The glyph's foreground

-- The face is a Lua module, written by build.lua from src/assets, rather than a file beside the
-- executable: an lde-compiled binary bundles the module and starts with nothing unpacked.
local ICON_FONT = wonderland.embedFont("beat.icons", require("beat.app.components.icon_font"))

-- Private-use points assigned when the face is generated from the SVGs. Keep these in step with
-- `tools/build-icon-font.cjs` if an icon is added: this table and the tool's must match.
local GLYPHS = {
play = 0xE000,
pause = 0xE001,
previous = 0xE002,
next = 0xE003,
shuffle = 0xE004,
["repeat"] = 0xE005,
repeatOne = 0xE006,
volume = 0xE007,
mute = 0xE008,
search = 0xE009,
home = 0xE00A,
library = 0xE00B,
folder = 0xE00C,
chevronLeft = 0xE00D,
chevronRight = 0xE00E,
chevronDown = 0xE00F,
chevronUp = 0xE010,
close = 0xE011,
check = 0xE012,
settings = 0xE013,
github = 0xE015,
tag = 0xE016,
playlists = 0xE017,
hand = 0xE018,
edit = 0xE019,
add = 0xE01A,
}

local UTF8_GLYPHS = {}
for name, codepoint in pairs(GLYPHS) do UTF8_GLYPHS[name] = utf8.char(codepoint) end

---@param app beat.App
---@param props beat.components.IconProps
---@return wonderland.Element
function icon.view(app, props)
	local glyph = UTF8_GLYPHS[props.name] or UTF8_GLYPHS.github
	local textElement = wonderland.text(glyph):style(sty():font(ICON_FONT):text(props.size):fg(props.colour))

	return div():style(sty():size(props.size, props.size):row():align("center"):justify("center"))
	:children(textElement)
end

return icon
