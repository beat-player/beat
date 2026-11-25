-- The clock, battery and gesture handle Android draws over the app, and the colour they need to
-- be read. The system keeps them white until an app asks otherwise, which leaves a day theme with
-- white icons on a near-white page. They follow the theme's background as the crossfade paints it,
-- so day gets dark icons and night or amoled keeps light ones; a custom accent does not change the
-- page behind them. Off Android this service does nothing.
local platform = require("beat.platform")
local dex = require("beat.app.services.system.dex")

-- Mid grey is where white and black icons read about equally against the background; above it
-- dark icons win. The palettes are far from this line, so the crossfade flips once, not often.
local LIGHT = 0.5

local Bars = {}
Bars.__index = Bars

--- How bright a #rrggbb or #rrggbbaa colour is, from 0 to 1. The alpha is the page's rather than
--- the icons', and a theme's background is opaque, so only the first six digits are read.
---@param colour string
local function luminance(colour)
	local hex = colour:match("^#(%x%x%x%x%x%x)")
	if hex == nil then return 0 end

	local r = tonumber(hex:sub(1, 2), 16) or 0
	local g = tonumber(hex:sub(3, 4), 16) or 0
	local b = tonumber(hex:sub(5, 6), 16) or 0
	return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
end

--- Whether dark icons are needed over `colour`. Exported so a test can hold the decision to the
--- palettes without a phone.
---@param colour string
---@return boolean
function Bars.isLight(colour)
	return luminance(colour) > LIGHT
end

---@class beat.BarsService
---@field appearance beat.AppearanceService
---@field bars any? # The Java SystemBars, as a global reference
---@field failed boolean # Loading or reaching the activity failed once; it is not tried every tick
---@field theme beat.Theme? # The theme whose background was last read
---@field light boolean? # The last appearance asked for; nil until the first one lands
local BarsService = {}
BarsService.__index = BarsService

---@param appearance beat.AppearanceService
---@return beat.BarsService
function Bars.new(appearance)
	---@type beat.BarsService
	local service = setmetatable({
		appearance = appearance,
		bars = nil,
		failed = false,
		theme = nil,
		light = nil
	}, BarsService)
	return service
end

--- Loads SystemBars and gives it the activity, which it keeps for the life of the process. The
--- dex module finds the class in the APK or writes the embedded copy out; the instance is global
--- because it holds the activity through app restarts.
local function load()
	---@diagnostic disable-next-line: missing-module
	local android = require("androidapi") --[[@as beat.AndroidApi]]
	local jni = android.jni
	local activity = assert(android.activity())
	local instance, err = jni.frame(function()
		local class = dex.class(jni, activity, "beat.SystemBars")
		local bars = jni.call(class, "java/lang/Class", "newInstance", "()Ljava/lang/Object;", "object")
		jni.call(bars, "java/util/function/Consumer", "accept", "(Ljava/lang/Object;)V", "void", activity.clazz)
		return jni.global(bars)
	end)
	if instance == nil then error(err or "SystemBars did not load", 0) end
	return instance
end

--- Asks for dark icons over a light page, or light ones over a dark page. Java posts the change to
--- the UI thread; the value crosses as a boxed Integer because the class is reached through
--- Consumer, the framework interface Lua can call by name.
---@param self beat.BarsService
---@param light boolean
---@return boolean ok
local function apply(self, light)
	---@diagnostic disable-next-line: missing-module
	local android = require("androidapi") --[[@as beat.AndroidApi]]
	local jni = android.jni
	local _, err = jni.frame(function()
		local value = jni.callStatic("java/lang/Integer", "valueOf", "(I)Ljava/lang/Integer;", light and 1 or 0)
		jni.call(self.bars, "java/util/function/Consumer", "accept", "(Ljava/lang/Object;)V", "void", value)
	end)
	if err ~= nil then
		require("beat.log").write("warn", "system bar appearance failed: " .. tostring(err))
		return false
	end
	return true
end

--- Watches the theme's background and changes the system bars only when its light or dark answer
--- changes: at launch, while a crossfade crosses the line, and when an automatic theme turns. It
--- reads nothing per frame otherwise.
---@param _now number
---@return boolean changed
---@return boolean busy
function BarsService:step(_now)
	if not platform.android or self.failed then return false, false end

	local appearance = self.appearance
	local theme = appearance.theme
	if theme == self.theme and appearance.fade == nil then return false, false end
	self.theme = theme

	local light = Bars.isLight(theme:color("bg"))
	if light == self.light then return false, false end

	if self.bars == nil then
		local ok, bars = pcall(load)
		if not ok or bars == nil then
			self.failed = true
			require("beat.log").write("warn", "system bar appearance is not available: " .. tostring(bars))
			return false, false
		end
		self.bars = bars
	end

	if not apply(self, light) then
		self.failed = true
		return false, false
	end

	self.light = light
	return false, false
end

return Bars
