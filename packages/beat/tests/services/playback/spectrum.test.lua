local test = require("lde-test")
local ffi = require("ffi")
local Spectrum = require("beat.app.services.playback.spectrum")

test.it("puts a sine wave in the upper half of the band strip", function()
	local samples = ffi.new("int16_t[?]", 512)
	local cycles = 64
	for at = 0, 511 do
		samples[at] = math.floor(math.sin(2 * math.pi * cycles * at / 512) * 20000)
	end

	local spectrum = Spectrum.new()
	spectrum:feed(samples, 512, 1)
	test.truthy(spectrum:step(1))

	local levels = spectrum:values()
	local best, bestAt = 0, 0
	for at, value in ipairs(levels) do
		if value > best then best, bestAt = value, at end
	end

	test.truthy(best > 0.3)
	test.truthy(bestAt > 16, "the low half is not the peak")
end)

test.it("decays when nothing new arrives", function()
	local samples = ffi.new("int16_t[?]", 512)
	for at = 0, 511 do samples[at] = 10000 end

	local spectrum = Spectrum.new()
	spectrum:feed(samples, 512, 1)
	test.truthy(spectrum:step(1))
	spectrum:clear()
	for _, value in ipairs(spectrum:values()) do test.equal(value, 0) end
end)

test.it("puts a pure tone in the band whose bins contain it", function()
	-- A full window -- no zero padding -- of a tone exactly on FFT bin `TONE`: its energy is in
	-- that bin, and the module's logarithmic band edges say which band owns it.
	local N = 1024
	local BANDS = 48
	local TONE = 32
	local samples = ffi.new("int16_t[?]", N)
	for at = 0, N - 1 do
		samples[at] = math.floor(math.sin(2 * math.pi * TONE * at / N) * 20000)
	end

	local half = N / 2
	local expected = 1
	for band = 1, BANDS do
		local lastBin = math.floor(half ^ (band / BANDS) + 0.5)
		if band == BANDS then lastBin = half - 1 end
		if lastBin >= TONE then
			expected = band
			break
		end
	end

	local spectrum = Spectrum.new()
	spectrum:feed(samples, N, 1)
	test.truthy(spectrum:step(1))

	local best, bestAt = 0, 0
	for at, value in ipairs(spectrum:values()) do
		if value > best then best, bestAt = value, at end
	end

	test.equal(bestAt, expected)
	test.truthy(best > 0.9)
end)

test.it("holds the last bands until a whole fresh window arrives after showing again", function()
	local N = 1024
	local samples = ffi.new("int16_t[?]", N)
	for at = 0, N - 1 do
		samples[at] = math.floor(math.sin(2 * math.pi * 32 * at / N) * 20000)
	end

	local spectrum = Spectrum.new()
	spectrum:feed(samples, N, 1)
	test.truthy(spectrum:step(1))

	local held = {}
	local brightest = 0
	for band, value in ipairs(spectrum:values()) do
		held[band] = value
		if value > brightest then brightest = value end
	end
	test.truthy(brightest > 0, "something is shown before the window goes away")

	-- The window was hidden and the tap stopped; feeding resumes at frame N and the app is told
	-- where the new timeline starts. Half a window is not yet a whole window of fresh audio.
	spectrum:resume(2)
	test.falsy(spectrum:step(2.001, N), "the frozen timeline is not analysed before the feed moves")

	local half = ffi.new("int16_t[?]", N / 2)
	for at = 0, N / 2 - 1 do half[at] = samples[at] end
	spectrum:feed(half, N / 2, 1, N)
	spectrum:sync(N + N / 2, N)

	local changed = spectrum:step(2.01, N + N / 2)
	test.falsy(changed, "a partial window is not analysed")
	for band, value in ipairs(spectrum:values()) do
		test.equal(value, held[band], "and the last bands are held")
	end

	-- The rest of the window: now the newest whole window is all fresh audio.
	local rest = ffi.new("int16_t[?]", N / 2)
	for at = 0, N / 2 - 1 do rest[at] = samples[N / 2 + at] end
	spectrum:feed(rest, N / 2, 1, N + N / 2)

	local moved = spectrum:step(2.02, N + N)
	test.truthy(moved, "the first whole fresh window moves the meter")
end)
