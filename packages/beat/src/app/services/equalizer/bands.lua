-- The math inside the equalizer service: the five bands it exposes, the presets that make them
-- useful without asking someone to know what 910 Hz should sound like, and the conversions between
-- saved gains, preset gains and the bands the audio player takes. Nothing outside the service's
-- folder needs the numbers without the rules that go with them.
-- The numbers are gains in dB; they are deliberately gentle enough that the preset names describe a
-- broad shape rather than a caricature, and the two bass presets move different parts of the low end.
local equalizer = {}

equalizer.frequencies = { 60, 230, 910, 3600, 14000}
equalizer.labels = { "60 Hz", "230 Hz", "910 Hz", "3.6 kHz", "14 kHz"}
equalizer.minimum = -12
equalizer.maximum = 12

---@class beat.EqualizerPreset
---@field id string
---@field name string
---@field gains number[]
---@field custom boolean?

---@class beat.EqualizerCustomPreset
---@field name string
---@field gains number[]

---@type beat.EqualizerPreset[]
equalizer.presets = {
{ id = "flat", name = "Flat", gains = { 0, 0, 0, 0, 0}},
{ id = "speaker", name = "Speaker", gains = { 4, 1, -1, 2, 3}},
{ id = "lowBass", name = "Low Bass", gains = { 8, 2, 0, 0, 0}},
{ id = "highBass", name = "High Bass", gains = { 2, 7, 2, 0, 0}},
{ id = "club", name = "DJ Club", gains = { 5, 3, 0, 2, 4}},
{ id = "vocal", name = "Vocal", gains = { -2, 0, 4, 3, 0}},
{ id = "treble", name = "Treble", gains = { -1, 0, 1, 4, 6}},
}

---@type table<string, beat.EqualizerPreset>
local byId = {}
for _, preset in ipairs(equalizer.presets) do byId[preset.id] = preset end

---@param id string?
---@return beat.EqualizerPreset?
function equalizer.preset(id)
	return id ~= nil and byId[id] or nil
end

---@param value any
---@param fallback number
---@return number
local function number(value, fallback)
	if type(value) ~= "number" or value ~= value then return fallback end
	return value
end

---@param value number
---@return number
function equalizer.clamp(value)
	return math.max(equalizer.minimum, math.min(equalizer.maximum, value))
end

--- A band table is what the audio player takes; a gains array is what settings and the screen
--- store. Keeping the conversion here means the two never disagree about order or count.
---@param gains number[]?
---@return treble.Equalizer.Band[]
function equalizer.bands(gains)
	local bands = {}
	for at, frequency in ipairs(equalizer.frequencies) do
			bands[at] = {
			frequency = frequency,
			gain = equalizer.clamp(number(gains and gains[at], 0)),
			q = 1.0,
			}
		end
	return bands
end

---@param gains number[]?
---@return number[]
function equalizer.sanitize(gains)
	local clean = {}
	for at = 1, #equalizer.frequencies do
			clean[at] = equalizer.clamp(number(gains and gains[at], 0))
		end
	return clean
end

---@param gains number[]
---@return number[]
function equalizer.copyGains(gains)
	local copy = {}
	for at = 1, #equalizer.frequencies do copy[at] = gains[at] or 0 end
	return copy
end

---@param id string?
---@return number[]
function equalizer.presetGains(id)
	local preset = equalizer.preset(id)
	if preset == nil then return equalizer.sanitize(nil) end
	local copy = {}
	for at = 1, #preset.gains do copy[at] = preset.gains[at] end
	return copy
end

return equalizer
