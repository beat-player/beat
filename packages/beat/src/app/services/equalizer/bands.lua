-- The math inside the equalizer service: the five bands it exposes, the presets that make them
-- useful without asking someone to know what 910 Hz should sound like, and the conversions between
-- saved gains, preset gains and the bands the audio player takes. Nothing outside the service's
-- folder needs the numbers without the rules that go with them.
-- The numbers are gains in dB; they are deliberately gentle enough that the preset names describe a
-- broad shape rather than a caricature, and the two bass presets move different parts of the low end.
local equalizer = {}

equalizer.frequencies = { 60, 230, 910, 3600, 14000 }
equalizer.labels = { "60 Hz", "230 Hz", "910 Hz", "3.6 kHz", "14 kHz" }
equalizer.minimum = -12
equalizer.maximum = 12

-- The preamp fader is shallower than a band's: it is a correction for the boosts above it, and
-- the imported profile brings its own preamp which is added on top. The sum the player hears is
-- held to the wider range the audio player's own preamp accepts.
equalizer.preampMinimum = -12
equalizer.preampMaximum = 6
equalizer.preampFloor = -24
equalizer.preampCeiling = 12

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
	{ id = "flat", name = "Flat", gains = { 0, 0, 0, 0, 0 } },
	{ id = "speaker", name = "Speaker", gains = { 4, 1, -1, 2, 3 } },
	{ id = "lowBass", name = "Low Bass", gains = { 8, 2, 0, 0, 0 } },
	{ id = "highBass", name = "High Bass", gains = { 2, 7, 2, 0, 0 } },
	{ id = "club", name = "DJ Club", gains = { 5, 3, 0, 2, 4 } },
	{ id = "vocal", name = "Vocal", gains = { -2, 0, 4, 3, 0 } },
	{ id = "treble", name = "Treble", gains = { -1, 0, 1, 4, 6 } }
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
local function number(value, fallback)
	if type(value) ~= "number" or value ~= value then return fallback end
	return value
end

---@param value number
---@return number
function equalizer.clamp(value)
	return math.max(equalizer.minimum, math.min(equalizer.maximum, value))
end

---@param value any
---@return number
function equalizer.clampPreamp(value)
	local preamp = number(value, 0)
	return math.max(equalizer.preampMinimum, math.min(equalizer.preampMaximum, preamp))
end

--- A band table is what the audio player takes; a gains array is what settings and the screen
--- store. Keeping the conversion here means the two never disagree about order or count.
---@param gains number[]?
---@return treble.Equalizer.Band[]
function equalizer.bands(gains)
	local bands = {}
	for at, frequency in ipairs(equalizer.frequencies) do
		bands[at] = { frequency = frequency, gain = equalizer.clamp(number(gains and gains[at], 0)), q = 1.0, type = "peak" }
	end
	return bands
end

--- The whole bank the player is given: the five faders first, then the imported profile's filters
--- underneath them, and the preamp as a hash field on the array. The profile's own preamp is added
--- to the fader's, because the two correct for different things -- the file for its boosts, the
--- person for their own -- and the player applies one gain before every filter.
---@param gains number[]?
---@param preamp number?
---@param profile beat.EqualizerProfile?
---@return treble.Equalizer.Band[]
function equalizer.combine(gains, preamp, profile)
	local combined = equalizer.bands(gains)
	if type(profile) == "table" and type(profile.filters) == "table" then
		for _, filter in ipairs(profile.filters) do
			combined[#combined + 1] = {
				frequency = filter.frequency,
				gain = filter.gain,
				q = filter.q,
				type = filter.type
			}
		end
	end
	local profilePreamp = type(profile) == "table" and number(profile.preamp, 0) or 0
	local total = equalizer.clampPreamp(preamp) + profilePreamp
	combined.preamp = math.max(equalizer.preampFloor, math.min(equalizer.preampCeiling, total))
	return combined
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

-- ────────────────────────────────────────────────────────────────
-- what the curve shows
-- ────────────────────────────────────────────────────────────────

-- The same RBJ shapes the audio player builds, at a rate the curve can be trusted at. A drawn
-- response is a picture, not playback, so the rate is fixed: the curve must not change shape
-- because whichever device happens to be open picked 44.1 or 48.
equalizer.curvePoints = 96
equalizer.curveMinimum = 20
equalizer.curveMaximum = 20000
equalizer.curveSampleRate = 48000

local LN10 = math.log(10)

--- The coefficients of one band, already divided by a0: b0, b1, b2, a1, a2.
---@param band treble.Equalizer.Band
---@param sampleRate number
---@return number[]?
local function coefficients(band, sampleRate)
	local frequency = number(band.frequency, 0)
	if frequency <= 0 or frequency >= sampleRate * 0.49 then return nil end
	local shape = band.type or "peak"
	local gain = number(band.gain, 0)
	local q = number(band.q, 0)
	if q <= 0 then q = 1.0 end

	local a = 10 ^ (gain / 40)
	local omega = 2 * math.pi * frequency / sampleRate
	local sine, cosine = math.sin(omega), math.cos(omega)
	local alpha = sine / (2 * q)
	local b0, b1, b2, a0, a1, a2

	if shape == "lowshelf" then
		local twoRootAlpha = 2 * math.sqrt(a) * alpha
		b0 = a * ((a + 1) - (a - 1) * cosine + twoRootAlpha)
		b1 = 2 * a * ((a - 1) - (a + 1) * cosine)
		b2 = a * ((a + 1) - (a - 1) * cosine - twoRootAlpha)
		a0 = (a + 1) + (a - 1) * cosine + twoRootAlpha
		a1 = -2 * ((a - 1) + (a + 1) * cosine)
		a2 = (a + 1) + (a - 1) * cosine - twoRootAlpha
	elseif shape == "highshelf" then
		local twoRootAlpha = 2 * math.sqrt(a) * alpha
		b0 = a * ((a + 1) + (a - 1) * cosine + twoRootAlpha)
		b1 = -2 * a * ((a - 1) + (a + 1) * cosine)
		b2 = a * ((a + 1) + (a - 1) * cosine - twoRootAlpha)
		a0 = (a + 1) - (a - 1) * cosine + twoRootAlpha
		a1 = 2 * ((a - 1) - (a + 1) * cosine)
		a2 = (a + 1) - (a - 1) * cosine - twoRootAlpha
	elseif shape == "lowpass" then
		b0 = (1 - cosine) / 2
		b1 = 1 - cosine
		b2 = (1 - cosine) / 2
		a0 = 1 + alpha
		a1 = -2 * cosine
		a2 = 1 - alpha
	elseif shape == "highpass" then
		b0 = (1 + cosine) / 2
		b1 = -(1 + cosine)
		b2 = (1 + cosine) / 2
		a0 = 1 + alpha
		a1 = -2 * cosine
		a2 = 1 - alpha
	else
		b0 = 1 + alpha * a
		b1 = -2 * cosine
		b2 = 1 - alpha * a
		a0 = 1 + alpha / a
		a1 = -2 * cosine
		a2 = 1 - alpha / a
	end

	return { b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0 }
end

--- The summed magnitude response of a bank, in dB, at `curvePoints` frequencies evenly spaced on a
--- log scale from 20 Hz to 20 kHz. The preamp is in the bank's hash field, as it is for the
--- player. This runs when the equalizer changes; a frame only plots the numbers it gave.
---@param bank treble.Equalizer.Band[]
---@return number[]
function equalizer.response(bank)
	local made = {}
	for at = 1, #bank do
		local band = bank[at]
		if type(band) == "table" then
			local c = coefficients(band, equalizer.curveSampleRate)
			if c ~= nil then made[#made + 1] = c end
		end
	end

	local count = equalizer.curvePoints
	local sampleRate = equalizer.curveSampleRate
	local lowest = equalizer.curveMinimum
	local step = math.log(equalizer.curveMaximum / lowest) / (count - 1)
	local logLowest = math.log(lowest)
	local preamp = number(bank.preamp, 0)
	local values = {}
	for index = 1, count do
		local frequency = math.exp(logLowest + step * (index - 1))
		local omega = 2 * math.pi * frequency / sampleRate
		local cosine, sine = math.cos(omega), math.sin(omega)
		local cosine2, sine2 = math.cos(2 * omega), math.sin(2 * omega)
		local total = preamp
		for at = 1, #made do
			local c = made[at]
			local nr = c[1] + c[2] * cosine + c[3] * cosine2
			local ni = -(c[2] * sine + c[3] * sine2)
			local dr = 1 + c[4] * cosine + c[5] * cosine2
			local di = -(c[4] * sine + c[5] * sine2)
			local denominator = dr * dr + di * di
			if denominator > 1e-12 then
				total = total + 10 * math.log((nr * nr + ni * ni) / denominator) / LN10
			end
		end
		values[index] = total
	end
	return values
end

--- Where a frequency sits across the curve, 0 at 20 Hz and 1 at 20 kHz.
---@param frequency number
---@return number
function equalizer.curveFraction(frequency)
	local hertz = number(frequency, 0)
	if hertz <= equalizer.curveMinimum then return 0 end
	if hertz >= equalizer.curveMaximum then return 1 end
	return math.log(hertz / equalizer.curveMinimum) / math.log(equalizer.curveMaximum / equalizer.curveMinimum)
end

return equalizer
