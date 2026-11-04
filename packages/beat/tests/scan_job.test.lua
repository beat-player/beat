local test = require("lde-test")
local fs = require("fs")
local json = require("json")
local ScanJob = require("beat.app.scan_job")

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
