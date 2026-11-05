-- The icon face lives in src/assets so lde copies it into the target before this runs. The app's
-- compiled executable carries Lua modules rather than a directory beside it, so the face becomes
-- one: `require("beat-ui.icons-font")` answers with its bytes in a source run and in a compiled
-- binary alike.
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

local face = build:read("assets/fonts/Ionicons.ttf")
build:write("icons-font.lua", "return \"" .. toLuaLiteral(face) .. "\"\n")
