-- A small FFT for the now-playing visualiser. Samples arrive from treble's PCM tap in int16 frames,
-- well before they are heard: the player decodes into a staging buffer ahead of the device. So the
-- tap only fills a ring of mono samples numbered on the device's timeline, and every step analyses
-- the window that ends at the frame being heard right now. The meter moves with what is heard, at
-- the frame rate, rather than jumping a fifth of a second early whenever a chunk is decoded.
-- The FFT is iterative Cooley-Tukey, on tables because the window is short.
local ffi = require("ffi")
local bit = require("bit")

local N = 1024
local BANDS = 48

-- The ring holds this many mono frames: more than the staging buffer and the device's own latency
-- put between a decoded frame and a heard one, at any sample rate the player opens.
local RING = 32768
local RING_MASK = RING - 1

-- How a level is read: decibels under the loudest band lately, `RANGE` of them from the top of the
-- strip to the floor. A linear or square-root scale squeezes a mix into the top third of the strip,
-- where nothing seems to move; on decibels a kick or a snare is a jump the eye can follow.
local RANGE = 44
local DECIBELS = 20 / math.log(10)

-- How long the loudest-band reference takes to fall to a third, in seconds: long enough that a
-- quiet bar does not fill the strip with noise, short enough that a quiet passage still moves it.
local TOP_FALL = 0.8

-- How a shown bar follows its level, as time constants in seconds: it rises almost at once, so a
-- hit lands on the frame it is heard, and falls quickly enough that the next one is a new jump.
local ATTACK = 0.018
local RELEASE = 0.06

-- With nothing new heard for this long -- paused, or between tracks -- the levels fall to rest
-- rather than holding the last window up.
local STALE = 0.12

---@class beat.Spectrum
---@field real number[]
---@field imag number[]
---@field window number[]
---@field ring ffi.cdata* # Mono samples, indexed by device frame modulo RING
---@field written number # The device frame after the last one the tap wrote
---@field floor number # The first frame of the current timeline: earlier ones are not this track's
---@field analysedAt number? # The heard frame the levels were last worked out for
---@field heardAt number? # When the heard frame last moved
---@field steppedAt number? # When `step` last ran, which is what the easing is timed by
---@field levels number[]
---@field display number[] # What the meter shows, eased toward `levels` every frame
---@field shown boolean
---@field peaks number[] # Uncompressed band peaks, kept for tuning the meter's response
---@field top number # The loudest band lately, which is the meter's reference
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
		ring = ffi.new("float[?]", RING),
		written = 0,
		floor = 0,
		analysedAt = nil,
		heardAt = nil,
		steppedAt = nil,
		levels = levels,
		display = display,
		shown = false,
		peaks = peaks,
		top = 0
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

--- Writes a decoded chunk into the ring, mixed to mono, at the device frames it will be heard at.
--- A chunk that starts before the last one ended is a new timeline -- a seek, a stop, another
--- track loaded -- and what the ring held before it is not this audio.
---@param samples ffi.cdata*
---@param frames number
---@param channels number
---@param startFrame number? # The device frame of its first sample; default right after the last chunk
function Spectrum:feed(samples, frames, channels, startFrame)
	if samples == nil or frames <= 0 then return end

	startFrame = startFrame or self.written
	if startFrame ~= self.written then
		self.floor = startFrame
		self.analysedAt = nil
	end

	local skip = math.max(0, frames - RING)
	local scale = 1 / (channels * 32768)
	local data = ffi.cast("int16_t*", samples)
	local ring = self.ring

	for at = skip, frames - 1 do
		local sum = 0
		local sampleAt = at * channels
		for channel = 0, channels - 1 do sum += data[sampleAt + channel] end
		ring[bit.band(startFrame + at, RING_MASK)] = sum * scale
	end

	self.written = startFrame + frames
end

--- Turns the magnitudes into bands. The band edges are logarithmic, which is what makes a bass note
--- and a cymbal both visible instead of one filling half the strip.
---@param self beat.Spectrum
---@param elapsed number # Seconds since the last analysis, which is what the reference falls by
local function bandsInto(self, elapsed)
	local real, imag, levels, peaks = self.real, self.imag, self.levels, self.peaks
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

	-- The reference is the loudest band lately, falling slowly, and never so low that the noise
	-- floor of a silent stretch is drawn as music.
	self.top = math.max(top, self.top * math.exp(-elapsed / TOP_FALL), 0.002)

	local reference = self.top
	for band = 1, BANDS do
		local peak = peaks[band]
		local value = 0
		if peak > 0 then
			value = 1 + DECIBELS * math.log(peak / reference) / RANGE
			if value < 0 then
				value = 0
			elseif value > 1 then
				value = 1
			end
			-- A steep curve keeps the quiet bands low and lets a hit reach most of the strip.
			value = value ^ 2.2
		end
		levels[band] = value
	end
end

--- Analyses the window that ends at the frame being heard, when that has moved, and eases the
--- shown meter toward it. Returns whether the meter changed, and whether it is still easing --
--- which is what says a frame is worth drawing every tick even after the audio has stopped.
---@param now number
---@param heard number? # The device frame being heard now; default the last frame fed
---@return boolean changed
---@return boolean easing
function Spectrum:step(now, heard)
	local changed = false
	local easing = false
	local elapsed = self.steppedAt ~= nil and math.max(0, now - self.steppedAt) or 0
	self.steppedAt = now

	local finish = math.min(heard or self.written, self.written)
	if finish > self.floor and finish ~= self.analysedAt then
		local sinceAnalysis = self.heardAt ~= nil and math.max(0, now - self.heardAt) or 0
		self.analysedAt = finish
		self.heardAt = now

		local real, imag, window, ring = self.real, self.imag, self.window, self.ring
		local oldest = math.max(self.floor, self.written - RING)
		local from = finish - N
		for at = 0, N - 1 do
			local frame = from + at
			real[at] = frame >= oldest and ring[bit.band(frame, RING_MASK)] * window[at] or 0
			imag[at] = 0
		end

		fft(real, imag)
		bandsInto(self, sinceAnalysis)
		changed = true
		easing = true
	elseif self.heardAt ~= nil and now - self.heardAt > STALE then
		-- Nothing new is being heard: the meter comes down rather than freezing on the last window.
		for band = 1, BANDS do self.levels[band] = 0 end
	end

	local rise = 1 - math.exp(-elapsed / ATTACK)
	local fall = 1 - math.exp(-elapsed / RELEASE)
	for band = 1, BANDS do
		local target = self.levels[band]
		local shown = self.display[band]

		if not self.shown then
			shown = target
		elseif target > shown then
			shown += (target - shown) * rise
		else
			shown += (target - shown) * fall
		end

		if math.abs(shown - self.display[band]) > 0.0005 then
			changed = true
			easing = true
		end
		self.display[band] = shown
	end
	self.shown = true

	return changed, easing
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
	self.written = 0
	self.floor = 0
	self.analysedAt = nil
	self.heardAt = nil
	self.steppedAt = nil
end

return Spectrum
