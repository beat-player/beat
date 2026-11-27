-- Reading a parametric equalizer profile as AutoEq writes one for EqualizerAPO:
--
--   Preamp: -6.1 dB
--   Filter 1: ON PK Fc 105 Hz Gain -2.3 dB Q 0.70
--   Filter 2: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.71
--
-- The text is the whole interface: profiles are copied from a page or picked from a file, never
-- typed into a form here. So the parser is deliberately forgiving -- extra spaces, Windows line
-- endings, `#` comments and lines it does not know are all skipped -- and strict about the one
-- thing that matters: a line only becomes a filter when its type is known, it is switched on and
-- it names a frequency. The numbers are held to the ranges the audio player accepts, so a stored
-- profile is always one the equalizer can play instead of a table it has to defend against.
--
-- This file holds no app or rendering code: the settings model reads a saved profile through it
-- at start, and the equalizer service reads a picked one.
local autoeq = {}

---@class beat.EqualizerFilter
---@field type "peak"|"lowshelf"|"highshelf"|"lowpass"|"highpass"
---@field frequency number # Hertz
---@field gain number # dB at the centre or shelf; ignored by low and high pass
---@field q number

---@class beat.EqualizerProfile
---@field name string
---@field preamp number # dB, the profile's own correction for the boosts below
---@field filters beat.EqualizerFilter[]

-- What a profile can hold. The same cap the settings model applies keeps a hand-edited file from
-- making the audio thread carry a filter bank it can never hear the end of.
autoeq.maximumFilters = 20

-- The ranges the audio player's bands accept. A preamp a profile asks for is clamped to them, so
-- an AutoEq file written for a different build still plays rather than being refused whole.
autoeq.preampMinimum = -24
autoeq.preampMaximum = 12
autoeq.gainMinimum = -24
autoeq.gainMaximum = 24
autoeq.qMinimum = 0.1
autoeq.qMaximum = 10
autoeq.frequencyMinimum = 10
autoeq.frequencyMaximum = 20000

-- EqualizerAPO's names for the shapes the player takes.
local TYPES = {
	PK = "peak",
	LS = "lowshelf",
	LSC = "lowshelf",
	HS = "highshelf",
	HSC = "highshelf",
	LP = "lowpass",
	LPQ = "lowpass",
	HP = "highpass",
	HPQ = "highpass"
}

-- A high or low pass has no bandwidth of its own to name, so a file that leaves Q out gets the
-- Butterworth value: the flattest passband rather than a resonance nobody asked for.
local DEFAULT_Q = {
	peak = 1.0,
	lowshelf = 0.707,
	highshelf = 0.707,
	lowpass = 0.707,
	highpass = 0.707
}

---@param value any
---@param fallback number
---@return number
local function number(value, fallback)
	if type(value) ~= "number" or value ~= value then return fallback end
	return value
end

---@param value number
---@param minimum number
---@param maximum number
---@return number
local function clamp(value, minimum, maximum)
	if value < minimum then return minimum end
	if value > maximum then return maximum end
	return value
end

--- Whether a name is one of the player's shapes, in either spelling a file may hold: the
--- EqualizerAPO short name (`LSC`) or the player's own (`lowshelf`).
---@param text any
---@return string?
local function filterType(text)
	if type(text) ~= "string" then return nil end
	local upper = text:upper()
	if TYPES[upper] ~= nil then return TYPES[upper] end
	for _, name in pairs(TYPES) do
		if name == text then return name end
	end
	return nil
end

---@param kind string
---@return number
function autoeq.defaultQ(kind)
	return DEFAULT_Q[kind] or 1.0
end

--- One filter, held to the ranges the player accepts. Nil when the shape is unknown or the
--- frequency is not a frequency: a band at 0 Hz is not something to rescue by guessing.
---@param kind string
---@param frequency any
---@param gain any
---@param q any
---@return beat.EqualizerFilter?
function autoeq.filter(kind, frequency, gain, q)
	local shape = filterType(kind)
	if shape == nil then return nil end
	local hertz = number(frequency, 0)
	if hertz <= 0 then return nil end
	hertz = clamp(hertz, autoeq.frequencyMinimum, autoeq.frequencyMaximum)

	local decibels = clamp(number(gain, 0), autoeq.gainMinimum, autoeq.gainMaximum)
	local bandwidth = number(q, 0)
	if bandwidth <= 0 then bandwidth = autoeq.defaultQ(shape) end
	bandwidth = clamp(bandwidth, autoeq.qMinimum, autoeq.qMaximum)

	return { type = shape, frequency = hertz, gain = decibels, q = bandwidth }
end

-- The number after a name, whether the file writes `Fc 105 Hz` or `Fc: 105`. The name is a Lua
-- pattern so the match ignores case without a second copy of every spelling.
---@param body string
---@param name string
---@return number?
local function field(body, name)
	local found = body:match(name .. "%s*:%s*([+-]?[%d%.]+)")
	if found == nil then found = body:match(name .. "%s+([+-]?[%d%.]+)") end
	return tonumber(found)
end

---@param body string
---@return beat.EqualizerFilter?
local function filterFrom(body)
	local status, kind = body:match("^([%a]+)%s+([%w]+)")
	if status == nil or status:upper() ~= "ON" then return nil end
	return autoeq.filter(kind, field(body, "[Ff][Cc]"), field(body, "[Gg][Aa][Ii][Nn]"), field(body, "[Qq]"))
end

--- A stored or imported profile, cleaned. A profile whose name or filters are not usable is nil:
--- a chip with no name and a bank with no bands are not profiles.
---@param profile any
---@return beat.EqualizerProfile?
function autoeq.sanitize(profile)
	if type(profile) ~= "table" then return nil end

	local name = type(profile.name) == "string" and profile.name:match("^%s*(.-)%s*$") or ""
	if name == "" then return nil end
	if #name > 80 then name = name:sub(1, 80) end

	local preamp = clamp(number(profile.preamp, 0), autoeq.preampMinimum, autoeq.preampMaximum)
	local filters = {}
	if type(profile.filters) == "table" then
		for _, item in ipairs(profile.filters) do
			local filter = type(item) == "table" and autoeq.filter(item.type, item.frequency, item.gain, item.q) or nil
			if filter ~= nil then filters[#filters + 1] = filter end
			if #filters >= autoeq.maximumFilters then break end
		end
	end

	-- A preamp on its own still shapes what plays, so it is a profile worth keeping.
	if #filters == 0 and preamp == 0 then return nil end

	return { name = name, preamp = preamp, filters = filters }
end

--- Reads a profile out of the file's text. The name is the caller's to give: the parser sees the
--- file, not the name it arrived under.
---@param text any
---@return beat.EqualizerProfile?
---@return string? err
function autoeq.parse(text)
	if type(text) ~= "string" or text:find("%S") == nil then return nil, "the profile text is empty" end

	local preamp = 0
	local sawPreamp = false
	local filters = {}

	-- Windows line endings and comments go before anything is matched, so a line pattern only has
	-- to describe the line itself.
	local lines = text:gsub("\r\n", "\n"):gsub("\r", "\n")
	for line in lines:gmatch("[^\n]*") do
		line = line:gsub("#.*$", "")

		local correction = line:match("^%s*[Pp][Rr][Ee][Aa][Mm][Pp]%s*:%s*([+-]?[%d%.]+)")
		if correction ~= nil then
			preamp = clamp(tonumber(correction) or 0, autoeq.preampMinimum, autoeq.preampMaximum)
			sawPreamp = true
		else
			local body = line:match("^%s*[Ff][Ii][Ll][Tt][Ee][Rr]%s*%d+%s*:%s*(.-)%s*$")
			if body ~= nil and #filters < autoeq.maximumFilters then
				local filter = filterFrom(body)
				if filter ~= nil then filters[#filters + 1] = filter end
			end
		end
	end

	if not sawPreamp and #filters == 0 then return nil, "no EqualizerAPO filters were found" end

	return { preamp = preamp, filters = filters }
end

return autoeq
