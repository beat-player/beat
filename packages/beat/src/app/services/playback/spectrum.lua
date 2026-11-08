-- A small FFT for the now-playing visualiser. Samples arrive from treble's PCM tap in int16 frames;
-- this keeps the last window, mixes it to mono, windows it, and turns the magnitudes into bands.
-- The FFT is iterative Cooley-Tukey, on tables because the window is short and decoding hands over
-- a chunk at a time.
local ffi = require("ffi")

local N = 1024
local BANDS = 48

---@class beat.Spectrum
---@field real number[]
---@field imag number[]
---@field window number[]
---@field levels number[]
---@field display number[] # What the meter shows, eased toward `levels` every frame
---@field shown boolean
---@field peaks number[] # Uncompressed band peaks, kept for tuning the meter's response
---@field top number # The loudest band lately, which is the meter's reference
---@field dirty boolean
local Spectrum = {}
Spectrum.__index = Spectrum

---@return beat.Spectrum
function Spectrum.new()
	local window = {}
	for at = 0, N - 1 do window[at] = 0.5 - 0.5 * math.cos(2 * math.pi * at / (N - 1)) end

	local levels, display, peaks = {}, {}, {}
	for at = 1, BANDS do levels[at], display[at], peaks[at] = 0, 0, 0 end

	return setmetatable({
		real = {},
		imag = {},
		window = window,
		levels = levels,
		display = display,
		shown = false,
		peaks = peaks,
		top = 0,
		dirty = false,
	}, Spectrum)
end

local function reverseBits(value)
	local out = 0
	for _ = 1, 10 do
		out = out * 2 + value % 2
		value = math.floor(value / 2)
	end
	return out
end

local function fft(real, imag)
	for at = 0, N - 1 do
		local reversed = reverseBits(at)
		if reversed > at then
			real[at], real[reversed] = real[reversed], real[at]
			imag[at], imag[reversed] = imag[reversed], imag[at]
		end
	end

	local size = 2
	while size <= N do
		local angle = -2 * math.pi / size
		local stepReal, stepImag = math.cos(angle), math.sin(angle)
		for start = 0, N - 1, size do
			local wr, wi = 1, 0
			local half = size / 2
			for at = 0, half - 1 do
				local even = start + at
				local odd = even + half
				local tr = wr * real[odd] - wi * imag[odd]
				local ti = wr * imag[odd] + wi * real[odd]
				real[odd] = real[even] - tr
				imag[odd] = imag[even] - ti
				real[even] += tr
				imag[even] += ti
				wr, wi = wr * stepReal - wi * stepImag, wr * stepImag + wi * stepReal
			end
		end
		size *= 2
	end
end

--- Copies the end of a decoded chunk into the FFT window, mixed to mono.
---@param samples ffi.cdata*
---@param frames number
---@param channels number
function Spectrum:feed(samples, frames, channels)
	if samples == nil or frames <= 0 then return end

	local count = math.min(frames, N)
	local base = (frames - count) * channels
	local scale = 1 / (channels * 32768)
	local data = ffi.cast("int16_t*", samples)

	for at = 0, N - 1 do
		self.real[at] = 0
		self.imag[at] = 0
	end

	for at = 0, count - 1 do
		local sum = 0
		local sampleAt = base + at * channels
		for channel = 0, channels - 1 do sum += data[sampleAt + channel] end
		self.real[at] = sum * scale * self.window[at]
	end

	self.dirty = true
end

--- Turns the magnitudes into a smoothed set of bands. The band edges are logarithmic, which is
--- what makes a bass note and a cymbal both visible instead of one filling half the strip.
local function bandsInto(real, imag, levels, peaks, spectrum)
	local half = N / 2
	local last = 1
	local top = 0

	for band = 1, BANDS do
		local first = math.max(1, last)
		local lastBin = math.floor(half ^ (band / BANDS) + 0.5)
		if lastBin < first then lastBin = first end
		if band == BANDS then lastBin = half - 1 end

		local peak = 0
		for bin = first, lastBin do
			-- FFT bins are scaled by the window length; bring a bin back to the amplitude of
			-- the signal so the meter's scale is the same at every FFT size.
			local magnitude = math.sqrt(real[bin] * real[bin] + imag[bin] * imag[bin]) * 2 / N
			if magnitude > peak then peak = magnitude end
		end

		-- Pink-ish tilt: a mix has far less energy at 10 kHz than at 100 Hz, so without it the
		-- right half of the strip is almost always dark. The boost is gentle and bounded.
		local fraction = (band - 1) / (BANDS - 1)
		peak *= 1 + 5 * fraction ^ 1.3

		peaks[band] = peak
		if peak > top then top = peak end
		last = lastBin + 1
	end

	-- Relative to the loudest band, with a slowly falling reference: a quiet passage still
	-- uses the strip, while the bass does not pin every bar at the top. The root lifts the
	-- small high-frequency values so cymbals and consonants are visible beside the kick.
	spectrum.top = math.max(top, spectrum.top * 0.9)

	for band = 1, BANDS do
		local value = 0
		if spectrum.top > 0.000001 then
			value = math.min(1, (peaks[band] / spectrum.top) ^ 0.5)
		end
		levels[band] = math.max(value, levels[band] * 0.88)
	end
end

--- Computes once per new PCM chunk. Returns whether the levels changed.
---@param _now number
---@return boolean
function Spectrum:step(_now)
	local changed = false

	if self.dirty then
		self.dirty = false
		fft(self.real, self.imag)
		bandsInto(self.real, self.imag, self.levels, self.peaks, self)
		changed = true
	end

	-- Audio is decoded in the player's staging buffer, which is deliberately larger than a
	-- frame so a late frame cannot starve the device. Ease the meter toward each new chunk
	-- between them so the strip still moves every frame.
	for band = 1, BANDS do
		local target = self.levels[band]
		local shown = self.display[band]

		if not self.shown then
			shown = target
		else
			shown += (target - shown) * 0.3
		end

		if math.abs(shown - self.display[band]) > 0.0005 then changed = true end
		self.display[band] = shown
	end
	self.shown = true

	return changed
end

--- The smoothed levels, low frequency first.
---@return number[]
function Spectrum:values()
	return self.display
end

function Spectrum:clear()
	for at = 1, BANDS do self.levels[at], self.display[at] = 0, 0 end
	self.top = 0
	self.shown = false
	self.dirty = false
end

return Spectrum
