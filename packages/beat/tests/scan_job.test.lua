local test = require("lde-test")
local fs = require("fs")
local json = require("json")
local ScanJob = require("beat.app.services.scan.job")

local function writeLines(file, values)
	local handle = assert(io.open(file, "w"))
	for _, value in ipairs(values) do handle:write(json.encode(value), "\n") end
	handle:close()
end

test.it("reads tracks, progress and completion in order", function()
	local output = os.tmpname() .. "-beat-scan-test.jsonl"
	local cancel = os.tmpname() .. "-beat-scan-test.cancel"
	writeLines(output, {
		{ type = "progress", phase = "inspect", files = 2, inspected = 0, tracks = 0, skipped = 0,
			errors = {}, current = "/music/a.flac" },
		{ type = "track", info = { format = "FLAC", duration = 10 }, entry = { path = "/music/a.flac",
			dir = "/music", name = "a.flac", ext = "flac" }, cover = nil },
		{ type = "track", info = { format = "FLAC", duration = 11 }, entry = { path = "/music/b.flac",
			dir = "/music", name = "b.flac", ext = "flac" }, cover = "/music/cover.jpg" },
		{ type = "progress", phase = "done", files = 2, inspected = 2, tracks = 2, skipped = 0,
			errors = {}, current = nil },
		{ type = "done", skipped = 0, errors = {} },
	})

	local job = ScanJob.new("/music", output, cancel)
	local events = job:poll(1)
	test.equal(#events, 1)
	test.equal(events[1].entry.name, "a.flac")
	test.equal(job:progress().inspected, 2, "progress is the latest progress line")
	test.truthy(job:hasPending(), "the second track is queued behind the first")
	test.truthy(job:isDone(), "the worker has already said it is done")

	local second = job:poll(1)
	test.equal(second[1].entry.name, "b.flac")
	local third = job:poll(1)
	test.equal(#third, 0)
	test.truthy(job:isDone())
	test.equal(job:progress().phase, "done")
	test.falsy(job:hasPending())
	job:close()
end)

test.it("keeps a partial JSON line for the next poll", function()
	local output = os.tmpname() .. "-beat-scan-partial.jsonl"
	local cancel = os.tmpname() .. "-beat-scan-partial.cancel"
	local handle = assert(io.open(output, "w"))
	handle:write('{"type":"track","info":{"duration":1},"entry":{"path":"/a","dir":"/","name":"a","ext":"wav"}}')
	handle:close()

	local job = ScanJob.new("/", output, cancel)
	test.equal(#job:poll(10), 0, "a line without its newline is not decoded")

	handle = assert(io.open(output, "a"))
	handle:write("\n")
	handle:close()
	test.equal(#job:poll(10), 1)
	job:close()
end)

test.it("fails a scan whose worker exits without finishing, once its output is read", function()
	local output = os.tmpname() .. "-beat-scan-exit.jsonl"
	local cancel = os.tmpname() .. "-beat-scan-exit.cancel"
	writeLines(output, {
		{ type = "track", info = { duration = 1 }, entry = { path = "/a", dir = "/", name = "a", ext = "wav" } },
	})

	local job = ScanJob.new("/", output, cancel)
	job.child = { poll = function() return 1 end }
	local events = job:poll(10)
	test.equal(#events, 1, "what the worker wrote before it exited is still delivered")
	test.falsy(job:isDone(), "the output was still being read when the exit was seen")

	job:poll(10)
	test.truthy(job:isDone(), "a worker that exited is not waited on forever")
	test.equal(job.error, "the scan stopped unexpectedly (exit code 1)")
	job:close()
end)

test.it("does not fail a scan whose worker exited after saying it was done", function()
	local output = os.tmpname() .. "-beat-scan-clean.jsonl"
	local cancel = os.tmpname() .. "-beat-scan-clean.cancel"
	writeLines(output, { { type = "done", skipped = 0, errors = {} } })

	local job = ScanJob.new("/", output, cancel)
	job.child = { poll = function() return 0 end }
	job:poll(10)
	job:poll(10)
	test.truthy(job:isDone())
	test.equal(job.error, nil)
	job:close()
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
	local time = require("wonderland.time")
	local root = os.tmpname() .. "-beat-scan-names"
	os.remove(root)
	fs.mkdirAll(root)
	local tone = assert(fs.read("tests/fixtures/tone.wav"))
	-- "Antônio" as Windows-1252 spells it: the bytes upstream fs reads on Windows.
	local foreign = root .. "/Ant\244nio.wav"
	assert(fs.write(root .. "/plain.wav", tone))
	assert(fs.write(foreign, tone))

	local job = ScanJob.start(root)
	local tracks = {}
	local started = time.now()
	while (not job:isDone() or job:hasPending()) and time.now() - started < 30 do
			for _, event in ipairs((job:poll(64))) do
					if event.type == "track" then tracks[#tracks + 1] = event.entry.name end
				end
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
