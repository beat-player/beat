-- The colours, type and spacing a screen is built from. A theme is data; a component asks for a
-- token and a transparency, never for a fixed hex value.
--
-- Private to the appearance service: the palettes and the choices it lists. A view reads the live
-- theme from `app.services.appearance.theme` and asks the service for a name or an accent, so this
-- module is never required from outside `services/appearance/`.
local sty = require("wonderland").sty

---@class beat.ThemeModule
---@field new fun(name: string?, accent: string?, scale: number?, fontFamily: string?): beat.Theme
---@field names fun(): string[]
---@field accents fun(): string[]
---@field accentColour fun(name: string): string
---@field accentInk fun(name: string): string
local theme = {}

local THEMES = {
	night = {
		bg = "#0b0c10",
		sidebar = "#07080a",
		surface = "#14161b",
		elevated = "#1b1e24",
		hover = "#23272f",
		active = "#2a2f38",
		text = "#f4f6f9",
		muted = "#9aa3b2",
		faint = "#6f7786",
		border = "#ffffff12",
		overlay = "#000000b8",
		scrim = "#000000a6",
		skeleton = "#ffffff0d",
		sheen = "#ffffff",
		danger = "#ff6b6b",
		success = "#7ee787",
		warning = "#ffc857",
	},
	day = {
		bg = "#f6f7f9",
		sidebar = "#ffffff",
		surface = "#ffffff",
		elevated = "#f0f1f4",
		hover = "#e7e9ee",
		active = "#dfe2e8",
		text = "#111318",
		muted = "#5c6474",
		faint = "#8a93a3",
		border = "#00000014",
		overlay = "#00000040",
		scrim = "#ffffffa6",
		skeleton = "#0000000a",
		sheen = "#ffffff",
		danger = "#c92a2a",
		success = "#2b8a3e",
		warning = "#b26a00",
	},
	amoled = {
		bg = "#000000",
		sidebar = "#000000",
		surface = "#0a0a0c",
		elevated = "#121216",
		hover = "#1a1a20",
		active = "#22222a",
		text = "#f7f7fa",
		muted = "#9b9ba6",
		faint = "#6d6d78",
		border = "#ffffff12",
		overlay = "#000000c8",
		scrim = "#000000b0",
		skeleton = "#ffffff0b",
		sheen = "#ffffff",
		danger = "#ff6b6b",
		success = "#7ee787",
		warning = "#ffc857",
	},
}

local ACCENTS = {
	lime = { colour = "#c9f45b", ink = "#0a0c08"},
	mint = { colour = "#5eead4", ink = "#05201c"},
	violet = { colour = "#b69cff", ink = "#150b2e"},
	coral = { colour = "#ff7a66", ink = "#2a0a06"},
	blue = { colour = "#6ea8ff", ink = "#06162e"},
	amber = { colour = "#ffc857", ink = "#2a1c00"},
}

--- The colour and ink an accent name or `#rrggbb` value means. A custom colour gets ink that
--- contrasts with it, since it did not come with one of the presets' hand-picked inks.
---@param value string?
---@return { colour: string, ink: string }?
---@return boolean # Whether the value was a custom hex colour
local function accentDefinition(value)
	if type(value) ~= "string" then return nil, false end

	local custom = value:match("^#(%x%x%x%x%x%x)$")
	if custom ~= nil then
		local r = tonumber(custom:sub(1, 2), 16) or 0
		local g = tonumber(custom:sub(3, 4), 16) or 0
		local b = tonumber(custom:sub(5, 6), 16) or 0
		local luminance = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
		return {
			colour = "#" .. custom:lower(),
			ink = luminance > 0.62 ? "#0a0c08" : "#f7f7fa",
		}, true
	end

	---@type { colour: string, ink: string }?
	local preset = ACCENTS[value]
	if preset ~= nil then return preset, false end
	return nil, false
end

local TYPE = {
	xs = 12,
	sm = 13,
	base = 14,
	md = 15,
	lg = 19,
	xl = 24,
	xxl = 30,
	hero = 46,
}

-- Below this, hinted grayscale text loses its counters and even spacing: a 90% UI scale would
-- otherwise bake an 11 px token at 10 px, which is where the small copy stopped reading cleanly.
local MIN_PIXEL_HEIGHT = 15

local RADII = {
	sm = 6,
	md = 8,
	lg = 10,
	xl = 14,
	hero = 20,
	full = 999,
}

---@param value string
local function parse(value)
	local hex = value:match("^#(%x+)$")
	if hex == nil then return 1, 1, 1, 1 end

	local r = tonumber(hex:sub(1, 2), 16) or 0
	local g = tonumber(hex:sub(3, 4), 16) or 0
	local b = tonumber(hex:sub(5, 6), 16) or 0
	local a = #hex >= 8 and (tonumber(hex:sub(7, 8), 16) or 255) or 255

	return r, g, b, a
end

local function hex(r, g, b, a)
	return string.format("#%02x%02x%02x%02x", math.floor(r + 0.5), math.floor(g + 0.5),
	math.floor(b + 0.5), math.floor(a + 0.5))
end

---@class beat.Theme
---@field name string
---@field accent string
---@field isDark boolean
---@field colors table<string, string>
---@field fromColors table<string, string>?
---@field mix number
---@field accentColour string
---@field accentInk string
---@field fontFamily string
---@field scale number
---@field color fun(self: beat.Theme, token: string, alpha: number?): string
---@field space fun(self: beat.Theme, value: number): number
---@field px fun(self: beat.Theme, value: number): number
---@field type fun(self: beat.Theme, name: string): number
---@field radius fun(self: beat.Theme, name: string): number
---@field s fun(self: beat.Theme): wonderland.StyleBuilder
local Theme = {}
Theme.__index = Theme

---@param name string?
---@param accent string?
---@param scale number?
---@param fontFamily string?
---@return beat.Theme
function theme.new(name, accent, scale, fontFamily)
	local palette = THEMES[name] or THEMES.night
	local chosen, custom = accentDefinition(accent)
	if chosen == nil then chosen = ACCENTS.lime end
	local colours = {}
	for key, value in pairs(palette) do colours[key] = value end
	colours.accent = chosen.colour
	colours.accentInk = chosen.ink

	return setmetatable({
		name = THEMES[name] ~= nil and name or "night",
		accent = custom and chosen.colour or (ACCENTS[accent] ~= nil and accent or "lime"),
		isDark = (THEMES[name] or THEMES.night) == THEMES.night or name == "amoled",
		colors = colours,
		fromColors = nil,
		mix = 1,
		accentColour = chosen.colour,
		accentInk = chosen.ink,
		fontFamily = fontFamily or "Inter",
		scale = scale or 1,
	}, Theme)
end

---@param token string
---@param alpha number?
---@return string
function Theme:color(token, alpha)
	local value = self.colors[token] or token
	if self.fromColors == nil and (alpha == nil or alpha >= 1) then return value end
	local r, g, b, a = parse(value)

	if self.fromColors ~= nil and self.mix < 1 then
		local from = self.fromColors[token] or token
		local fr, fg, fb, fa = parse(from)
		local t = math.max(0, math.min(1, self.mix))
		r = fr + (r - fr) * t
		g = fg + (g - fg) * t
		b = fb + (b - fb) * t
		a = fa + (a - fa) * t
	end

	if alpha == nil or alpha >= 1 then return hex(r, g, b, a) end
	return hex(r, g, b, a * math.max(0, alpha))
end

---@param value number
---@return number
function Theme:space(value)
	return math.floor(value * self.scale + 0.5)
end

---@param value number
---@return number
function Theme:px(value)
	return math.floor(value * self.scale + 0.5)
end

---@param name string
---@return number
function Theme:type(name)
	return math.max(MIN_PIXEL_HEIGHT, math.floor((TYPE[name] or TYPE.base) * self.scale + 0.5))
end

---@param name string
---@return number
function Theme:radius(name)
	return math.floor((RADII[name] or RADII.md) * self.scale + 0.5)
end

--- A builder with the family this theme draws in. Every text style starts here.
---@return wonderland.StyleBuilder
function Theme:s()
	return sty():font(self.fontFamily)
end

---@return string[]
function theme.names()
	local list = {}
	for name in pairs(THEMES) do list[#list + 1] = name end
	table.sort(list)
	return list
end

---@return string[]
function theme.accents()
	local list = {}
	for name in pairs(ACCENTS) do list[#list + 1] = name end
	table.sort(list)
	return list
end

---@param name string
---@return string
function theme.accentColour(name)
	local chosen = accentDefinition(name)
	return chosen?.colour or ACCENTS.lime.colour
end

---@param name string
---@return string
function theme.accentInk(name)
	local chosen = accentDefinition(name)
	return chosen?.ink or ACCENTS.lime.ink
end

return theme
