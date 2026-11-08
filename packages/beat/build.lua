-- Build-time assets. The app icon and the icon face live under src/assets, which lde copies into
-- the target before this runs. A compiled app carries no asset directory beside it, so the bytes
-- are written as Lua strings in the package target: `require("beat.app.icon")` and
-- `require("beat.app.components.icon_font")` work from source and from an `lde compile`d
-- executable alike.
local build = require("lde-build")

local escapes = {
	[34] = '\\"',
	[92] = "\\\\",
	[9] = "\\t",
	[10] = "\\n",
	[13] = "\\r",
}

--- Escapes the bytes of a binary so they survive as a Lua string literal.
---@param data string
---@return string
local function toLuaLiteral(data)
	return (data:gsub("[%z\1-\31\\\"]", function(char)
		return escapes[char:byte()] or string.format("\\%03d", char:byte())
	end))
end

local icon = build:read("assets/icon-256.png")
build:write("app/icon.lua", "return \"" .. toLuaLiteral(icon) .. "\"\n")

-- The Ionicons face the icon component draws its glyphs from. It is embedded the same way: a
-- compiled binary starts with nothing unpacked, so the face has to travel as a module.
local face = build:read("assets/fonts/Ionicons.ttf")
build:write("app/components/icon_font.lua", "return \"" .. toLuaLiteral(face) .. "\"\n")
