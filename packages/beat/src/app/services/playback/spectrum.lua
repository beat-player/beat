-- A small FFT for the now-playing visualiser. Samples arrive from treble's PCM tap in int16 frames,
-- well before they are heard: the player decodes into a staging buffer ahead of the device. So the
-- tap only fills a ring of mono samples numbered on the device's timeline, and every step analyses
-- the window that ends at the frame being heard right now. The meter moves with what is heard, rather
-- than jumping a fifth of a second early whenever a chunk is decoded.
--
-- The FFT is iterative Cooley-Tukey. Its buffers, the window and the twiddles are ffi double arrays
-- made once, and the bit-reversal permutation is folded into two module-level swap lists, so a step
-- neither allocates nor re-derives what the previous step already knew. The meter is analysed at
-- 30 Hz and only eased in between: the FFT is not what the eye needs at 60 Hz.
local ffi = require("ffi")
local bit = require("bit")
local PcmRing = require("beat.app.services.playback.pcm")

local N = 1024
local BANDS = 48
local HALF = N / 2

-- The ring holds this many mono frames: more than the staging buffer and the device's own latency
-- put between a decoded frame and a heard one, at any sample rate the player opens.
local RING = PcmRing.CAPACITY
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

-- How often the spectrum is worked out. Twice the animation's own 30 Hz: a fast 30 Hz animation
-- reading a 60 Hz meter sees every other window, while a 60 Hz animation reading a 30 Hz meter is
-- what a display-rate repaint has always shown. The bars ease between analyses.
local ANALYSIS = 1 / 30

-- The ffi types are looked up once: `ffi.typeof` in a hot function is a per-call allocation.
local DOUBLE = ffi.typeof("double[?]")
local FLOAT = ffi.typeof("float[?]")

-- The Hann window, shared by every instance because nothing writes to it.
local WINDOW = ffi.new(DOUBLE, N)
for at = 0, N - 1 do WINDOW[at] = 0.5 - 0.5 * math.cos(2 * math.pi * at / (N - 1)) end

-- The twiddles of every stage of the FFT: stage `size` reads index `at * N / size`, and no stage
-- needs more than `N / 2` of them. Precomputing also stops the recurrence's rounding drift.
local TWIDDLE_COS = ffi.new(DOUBLE, HALF)
local TWIDDLE_SIN = ffi.new(DOUBLE, HALF)
for at = 0, HALF - 1 do
	local angle = -2 * math.pi * at / N
	TWIDDLE_COS[at] = math.cos(angle)
	TWIDDLE_SIN[at] = math.sin(angle)
end

-- The bit-reversal permutation as the swaps it comes to: a pair of indices per swap, made once
-- per FFT size rather than reversed per element on every analysis.
local SWAP_FROM = ffi.new("uint16_t[?]", N)
local SWAP_TO = ffi.new("uint16_t[?]", N)
local SWAP_COUNT = 0
do
	local reversed = {}
	for at = 0, N - 1 do
		local value, out = at, 0
		for _ = 1, 10 do
			out = out * 2 + bit.band(value, 1)
			value = bit.rshift(value, 1)
		end
		reversed[at] = out
	end
	for at = 0, N - 1 do
		local to = reversed[at]
		if to > at then
			SWAP_FROM[SWAP_COUNT] = at
			SWAP_TO[SWAP_COUNT] = to
			SWAP_COUNT = SWAP_COUNT + 1
		end
	end
end

---@class beat.Spectrum
---@field real ffi.cdata* # double[N], the FFT's real part
---@field imag ffi.cdata* # double[N], the FFT's imaginary part
---@field ring ffi.cdata* # Mono samples, indexed by device frame modulo RING
---@field written number # The device frame after the last one the tap wrote
---@field floor number # The first frame of the current timeline: earlier ones are not this track's
---@field analysedAt number? # The heard frame the levels were last worked out for
---@field heardAt number? # When the heard frame last moved
---@field lastAnalysis number? # When the FFT last ran, which is what the analysis rate is timed by
---@field steppedAt number? # When `step` last ran, which is what the easing is timed by
---@field levels number[]
---@field display number[] # What the meter shows, eased toward `levels` every frame
---@field shown boolean
---@field peaks number[] # Uncompressed band peaks, kept for tuning the meter's response
---@field top number # The loudest band lately, which is the meter's reference
local Spectrum = {}
Spectrum.__index = Spectrum

---@param ring ffi.cdata*? # The mono ring to read; by default one of this instance's own
---@return beat.Spectrum
function Spectrum.new(ring)
	local levels, display, peaks = {}, {}, {}
	for at = 1, BANDS do levels[at], display[at], peaks[at] = 0, 0, 0 end

	return setmetatable({
		real = ffi.new(DOUBLE, N),
		imag = ffi.new(DOUBLE, N),
		ring = ring or ffi.new(FLOAT, RING),
		written = 0,
		floor = 0,
		analysedAt = nil,
		heardAt = nil,
		lastAnalysis = nil,
		steppedAt = nil,
		levels = levels,
		display = display,
		shown = false,
		peaks = peaks,
		top = 0
	}, Spectrum)
end

---@param real ffi.cdata*
---@param imag ffi.cdata*
local function fft(real, imag)
	local from, to = SWAP_FROM, SWAP_TO
	for at = 0, SWAP_COUNT - 1 do
		local even, odd = from[at], to[at]
		local tr, ti = real[even], imag[even]
		real[even], imag[even] = real[odd], imag[odd]
		real[odd], imag[odd] = tr, ti
	end

	local cosines, sines = TWIDDLE_COS, TWIDDLE_SIN
	local size = 2
	while size <= N do
		local half = size / 2
		local step = N / size
		for start = 0, N - 1, size do
			local index = 0
			for at = 0, half - 1 do
				local even = start + at
				local odd = even + half
				local wr, wi = cosines[index], sines[index]
				local tr = wr * real[odd] - wi * imag[odd]
				local ti = wr * imag[odd] + wi * real[odd]
				real[odd] = real[even] - tr
				imag[odd] = imag[even] - ti
				real[even] = real[even] + tr
				imag[even] = imag[even] + ti
				index = index + step
			end
		end
		size = size * 2
	end
end

--- Writes a decoded chunk into the ring, mixed to mono, at the device frames it will be heard at.
--- A chunk that starts before the last one ended is a new timeline -- a seek, a stop, another
--- track loaded -- and what the ring held before it is not this audio.
--- The mono and stereo cases are flat loops of their own: a track is almost always one or the
--- other, and the inner per-channel loop only pays when the device is neither.
---@param samples ffi.cdata* # int16 samples
---@param frames number
---@param channels number
---@param startFrame number? # The device frame of its first sample; default right after the last chunk
function Spectrum:feed(samples, frames, channels, startFrame)
	if samples == nil or frames <= 0 then return end

	startFrame = startFrame or self.written
	if startFrame ~= self.written then
		self.floor = startFrame
		self.analysedAt = nil
		self.lastAnalysis = nil
	end

	local skip = math.max(0, frames - RING)
	local ring, mask = self.ring, RING_MASK
	local data = samples
	local scale = 1 / 32768

	if channels == 1 then
		for at = skip, frames - 1 do
			ring[bit.band(startFrame + at, mask)] = data[at] * scale
		end
	elseif channels == 2 then
		local mixed = 0.5 * scale
		for at = skip, frames - 1 do
			local index = at * 2
			ring[bit.band(startFrame + at, mask)] = (data[index] + data[index + 1]) * mixed
		end
	else
		local channelScale = 1 / (channels * 32768)
		for at = skip, frames - 1 do
			local index = at * channels
			local sum = 0
			for channel = 0, channels - 1 do sum = sum + data[index + channel] end
			ring[bit.band(startFrame + at, mask)] = sum * channelScale
		end
	end

	self.written = startFrame + frames
end

--- Moves the ring's timeline to what the audio thread last wrote. The samples themselves cross in
--- the shared ring; this only carries the two frame counts a snapshot knows. A written frame
--- going backwards is a new timeline -- a reload, a seek, a stop -- and what the ring held before
--- it is not this track's audio.
---@param written number?
---@param floor number?
function Spectrum:sync(written, floor)
	if written == nil then return end
	if written == self.written and (floor == nil or floor == self.floor) then return end

	if written < self.written or (floor ~= nil and floor ~= self.floor) then
		self.floor = floor or 0
		self.analysedAt = nil
		self.heardAt = nil
		self.lastAnalysis = nil
	end
	self.written = written
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

--- Analyses the window that ends at the frame being heard, when that has moved and a step is due,
--- and eases the shown meter toward it. Returns whether the meter changed, and whether it is still
--- easing -- which is what says a frame is worth drawing every tick even after the audio has stopped.
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
		-- The bands move with the music, but the FFT only runs as often as the eye can read it:
		-- between analyses the display eases toward the bands the last one left.
		if self.lastAnalysis == nil or now - self.lastAnalysis >= ANALYSIS then
			local sinceAnalysis = self.heardAt ~= nil and math.max(0, now - self.heardAt) or 0
			self.lastAnalysis = now
			self.analysedAt = finish
			self.heardAt = now

			local real, imag, window, ring = self.real, self.imag, WINDOW, self.ring
			local oldest = math.max(self.floor, self.written - RING)
			local from = finish - N
			for at = 0, N - 1 do
				local frame = from + at
				if frame >= oldest then
					real[at] = ring[bit.band(frame, RING_MASK)] * window[at]
				else
					real[at] = 0
				end
				imag[at] = 0
			end

			fft(real, imag)
			bandsInto(self, sinceAnalysis)
			changed = true
			easing = true
		end
	elseif self.heardAt ~= nil and now - self.heardAt > STALE then
		-- Nothing new is being heard: the meter comes down rather than freezing on the last window.
		for band = 1, BANDS do self.levels[band] = 0 end
	end

	local rise = 1 - math.exp(-elapsed / ATTACK)
	local fall = 1 - math.exp(-elapsed / RELEASE)
	local levels, display = self.levels, self.display
	for band = 1, BANDS do
		local target = levels[band]
		local shown = display[band]

		if not self.shown then
			shown = target
		elseif target > shown then
			shown = shown + (target - shown) * rise
		else
			shown = shown + (target - shown) * fall
		end

		if math.abs(shown - display[band]) > 0.0005 then
			changed = true
			easing = true
		end
		display[band] = shown
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
	self.lastAnalysis = nil
	self.steppedAt = nil
end

return Spectrum
