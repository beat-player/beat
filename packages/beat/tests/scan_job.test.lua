-- A scan runs on threads of the app's own process: the folder is walked a slice a tick, then
-- inspected in four shards at once, and every track crosses back through a channel. These tests
-- run real scans over the fixture tones, because what they check is the hand-off between the
-- walk, the inspector threads and the job that the service polls -- not an output format.
local test = require("lde-test")
local fs = require("fs")
local path = require("path")
local threading = require("threading")
local ScanJob = require("beat.app.services.scan.job")
local time = require("wonderland.time")

local TONE = assert(fs.read("tests/fixtures/tone.wav"))

---@param suffix string
---@return string
local function folder(suffix)
	-- Normalized, as the scanner normalizes the root it is given: a temporary directory can come
	-- back with a doubled separator (macOS's TMPDIR ends in one), and a path built from it would
	-- not be the path the scan reports for the same file.
	local root = path.normalize(os.tmpname() .. suffix)
	os.remove(root)
	fs.mkdirAll(root)
	return root
end

---@param root string
local function removeFiles(root)
	local iterator = fs.readdir(root)
	if iterator == nil then return end
	for entry in iterator do
		if entry.type == "file" then fs.delete(root .. "/" .. entry.name) end
	end
end

--- Polls a job until it ends, collecting what it hands over. The threads need the scheduler
--- between polls, so an empty poll waits a millisecond rather than spinning.
---@param job beat.ScanJob
---@return table[] events
local function drain(job)
	local events = {}
	local started = time.now()

	while (not job:isDone() or job:hasPending()) and time.now() - started < 30 do
		local batch = job:poll(64)
		for _, event in ipairs(batch) do events[#events + 1] = event end
		if #batch == 0 then threading.sleep(1) end
	end

	return events
end

test.it("reads a folder on inspector threads and reports every track", function()
	local root = folder("-beat-scan-tracks")
	assert(fs.write(root .. "/a.wav", TONE))
	assert(fs.write(root .. "/b.wav", TONE))

	local job = ScanJob.start(root)
	local events = drain(job)
	local progress = job:progress()
	job:close()

	removeFiles(root)
	fs.rmdir(root)

	test.equal(job.error, nil, "the scan finishes instead of failing")
	test.equal(progress.phase, "done")
	test.equal(progress.files, 2)
	test.equal(progress.inspected, 2)
	test.equal(progress.tracks, 2)
	test.equal(progress.skipped, 0)
	test.equal(#events, 2, "every track is handed to the service")

	local names = {}
	for _, event in ipairs(events) do
		test.equal(event.type, "track")
		test.equal(event.info.format, "WAV")
		names[event.entry.name] = true
	end
	test.truthy(names["a.wav"])
	test.truthy(names["b.wav"])
end)

test.it("finishes an empty folder without starting an inspector", function()
	local root = folder("-beat-scan-empty")

	local job = ScanJob.start(root)
	local events = drain(job)
	local progress = job:progress()
	job:close()

	fs.rmdir(root)

	test.equal(job.error, nil)
	test.equal(progress.phase, "done")
	test.equal(progress.files, 0)
	test.equal(#events, 0)
end)

test.it("reports a file it cannot read and carries on", function()
	local root = folder("-beat-scan-bad")
	assert(fs.write(root .. "/broken.wav", "not audio"))
	assert(fs.write(root .. "/good.wav", TONE))

	local job = ScanJob.start(root)
	local events = drain(job)
	local progress = job:progress()
	job:close()

	removeFiles(root)
	fs.rmdir(root)

	test.equal(job.error, nil)
	test.equal(progress.phase, "done")
	test.equal(progress.tracks, 1)
	test.equal(progress.skipped, 1)
	test.equal(#events, 1)
	test.equal(progress.errors[1] and progress.errors[1].message, "not an audio file this library reads")
end)

test.it("cancels a running scan and the next scan reuses its threads", function()
	local root = folder("-beat-scan-cancel")
	for at = 1, 32 do assert(fs.write(root .. "/tone-" .. at .. ".wav", TONE)) end

	local job = ScanJob.start(root)
	-- One poll walks the folder and starts the inspectors; the scan is then cut short while they
	-- are reading, which is what a cancel during a scan looks like.
	job:poll(0)
	test.truthy(job:cancel())
	test.truthy(job:isDone())
	test.equal(#job:poll(64), 0, "a cancelled scan hands nothing more over")
	job:close()

	-- The cancelled threads are joined by the next scan rather than by the cancel itself.
	local second = ScanJob.start(root)
	local events = drain(second)
	second:close()

	removeFiles(root)
	fs.rmdir(root)

	test.equal(second.error, nil, "the scan after a cancel still runs")
	test.equal(#events, 32)
end)

-- Whether a file can be named with bytes that are not UTF-8: upstream fs on Windows (narrow calls,
-- the system code page) and most POSIX filesystems can; an fs that speaks UTF-16 to Windows cannot,
-- and there no scan meets such a name.
local function canNameNonUtf8()
	local probe = os.tmpname() .. "-beat-name-\244"
	if not fs.write(probe, "") then return false end
	fs.delete(probe)
	return true
end

test.skipIf(not canNameNonUtf8())("scans past a file whose name is not UTF-8 and reports it", function()
	local root = folder("-beat-scan-names")
	-- "Antônio" as Windows-1252 spells it: the bytes upstream fs reads on Windows.
	local foreign = root .. "/Ant\244nio.wav"
	assert(fs.write(root .. "/plain.wav", TONE))
	assert(fs.write(foreign, TONE))

	local job = ScanJob.start(root)
	---@type string[]
	local tracks = {}
	for _, event in ipairs(drain(job)) do
		if event.type == "track" then tracks[#tracks + 1] = event.entry.name end
	end
	local progress = job:progress()
	job:close()

	fs.delete(root .. "/plain.wav")
	fs.delete(foreign)
	fs.rmdir(root)

	test.equal(job.error, nil, "the scan finishes instead of dying on the name")
	test.equal(progress.phase, "done")
	test.equal(#tracks, 1)
	test.equal(tracks[1], "plain.wav")
	test.equal(progress.skipped, 1)
	test.equal(progress.errors[1] and progress.errors[1].message, "skipped: its name is not UTF-8")
end)

test.it("takes a file whose modification time has not changed from the records it was given", function()
	local root = folder("-beat-scan-reuse")
	-- Joined with the platform's separator, as the scanner joins the paths it reports: a record is
	-- matched to a file by its path, and Windows's is written with backslashes.
	local unchanged = path.join(root, "unchanged.wav")
	local changed = path.join(root, "changed.wav")
	assert(fs.write(unchanged, TONE))
	assert(fs.write(changed, TONE))

	-- A record of the first file as an earlier scan read it. It says nothing true about the file,
	-- so a reused event carrying this title proves the inspector did not open it.
	local stat = assert(fs.stat(unchanged))
	local record = {
		path = unchanged,
		key = "single\0" .. unchanged,
		title = "already read",
		artist = "a test",
		album = "already read",
		albumArtist = "a test",
		duration = 1,
		format = "WAV",
		sampleRate = 48000,
		channels = 2,
		hasPicture = false,
		modified = assert(stat.modifyTime)
	}

	local job = ScanJob.start(root, { record })
	local reused, scanned = 0, 0
	local reusedTitle = nil
	for _, event in ipairs(drain(job)) do
		if event.type == "reused" then
			reused += 1
			reusedTitle = event.record and event.record.title
		elseif event.type == "track" then
			scanned += 1
		end
	end
	local progress = job:progress()
	job:close()

	fs.delete(unchanged)
	fs.delete(changed)
	fs.rmdir(root)

	test.equal(job.error, nil)
	test.equal(reused, 1, "the file the record describes is not read again")
	test.equal(reusedTitle, "already read")
	test.equal(scanned, 1, "the file it does not describe is read")
	test.equal(progress.phase, "done")
	test.equal(progress.tracks, 2, "both files are in what the scan reports")
end)
