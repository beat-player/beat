-- Build-time assets. The app icon lives under src/assets, which lde copies into the target before
-- this runs. A compiled app carries no asset directory beside it, so the bytes are written as a
-- Lua string in the package target: `require("beat.app.icon")` works from source and from an
-- `lde compile`d executable alike.
--
-- The version is generated the same way: `require("beat.version")` is "0.1.0" in a release build
-- and "0.1.0-nightly+<short-hash>" in every other build. CI sets LDE_RELEASE=1 for a release.
local build = require("lde-build")

local BASE_VERSION = "0.1.0"

local releaseEnv = os.getenv("LDE_RELEASE")
local release = releaseEnv ~= nil and releaseEnv ~= ""

local hash
if not release then
	-- io.popen shells out through cmd.exe on Windows, so the redirect differs.
	local null = jit.os == "Windows" ? "2>nul" : "2>/dev/null"
	local handle = io.popen("git rev-parse --short=7 HEAD " .. null)
	if handle then
		local out = handle:read("*l")
		handle:close()
		if out and out:match("^%x+$") then
			hash = out
		end
	end
end

local version
if release then
	version = BASE_VERSION
elseif hash then
	version = BASE_VERSION .. "-nightly+" .. hash
else
	version = BASE_VERSION .. "-dev"
end

build:write("version.lua", string.format("return %q\n", version))

local escapes = { [34] = '\\"', [92] = "\\\\", [9] = "\\t", [10] = "\\n", [13] = "\\r" }

--- Escapes the bytes of a binary so they survive as a Lua string literal.
---@param data string
local function toLuaLiteral(data)
	return (data:gsub("[%z\1-\31\\\"]", function(char)
		return escapes[char:byte()] or string.format("\\%03d", char:byte())
	end))
end

local icon = build:read("assets/icon-256.png")
build:write("app/icon.lua", "return \"" .. toLuaLiteral(icon) .. "\"\n")

-- The Android media session's Java half (android/build-dex.sh), loaded at run time by
-- `beat.app.services.system.media`: a NativeActivity APK carries no Java code of its own.
local mediaDex = build:read("assets/media.dex")
build:write("app/media_dex.lua", "return \"" .. toLuaLiteral(mediaDex) .. "\"\n")
