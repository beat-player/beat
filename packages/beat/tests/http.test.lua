-- The shared network service, against a stand-in for libcurl's multi handle: what it queues, how
-- many transfers it runs at once, and what a download leaves behind when it fails. Nothing here
-- touches the network.
local test = require("lde-test")
local fs = require("fs")
local path = require("path")
local Http = require("beat.app.services.http")

---@class TestBatch
---@field order table[]
---@field closed boolean
---@field writePart boolean
---@field pumpError string?
---@field config table
local TestBatch = {}
TestBatch.__index = TestBatch

---@param self TestBatch
---@param url string
---@param opts table
---@return number
function TestBatch:add(url, opts)
	local state = { url = url, opts = opts, httpStatus = self.config.failStatus or 200 }
	self.order[#self.order + 1] = state
	if self.writePart and opts.path ~= nil then fs.write(opts.path, "downloaded bytes") end
	return #self.order
end

---@param self TestBatch
---@return number
function TestBatch:pump()
	if self.pumpError ~= nil then error(self.pumpError) end
	return 0
end

---@param self TestBatch
function TestBatch:close() self.closed = true end

---@return table curl, table batches
local function fakeCurl()
	local batches = {}
	local config = {}
	local curl = {
		config = config,
		batch = function()
			local batch = setmetatable({ order = {}, closed = false, writePart = true, config = config }, TestBatch)
			batches[#batches + 1] = batch
			return batch
		end
	}
	return curl, batches
end

local function tempDir()
	local dir = os.tmpname() .. "-beat-http"
	os.remove(dir)
	fs.mkdirAll(dir)
	return dir
end

local function removeTree(dir)
	local iterator = fs.readdir(dir)
	if iterator ~= nil then
		for entry in iterator do
			local full = path.join(dir, entry.name)
			if entry.type == "directory" then
				removeTree(full)
			else
				fs.delete(full)
			end
		end
	end
	fs.rmdir(dir)
end

test.it("answers a request on the tick, not when it is made", function()
	local curl, batches = fakeCurl()
	local service = Http.new({ curl = curl })
	local responses = {}

	service:request({ url = "https://example.test/search?q=album", onDone = function(response) responses[#responses + 1] = response end })
	test.equal(#batches, 0, "nothing starts before the ticker runs")
	test.equal(#responses, 0, "the callback waits for the ticker")

	local changed, busy = service:step(0)
	test.truthy(changed)
	test.truthy(busy)
	test.equal(#batches, 1)
	test.equal(batches[1].order[1].url, "https://example.test/search?q=album")
	test.equal(batches[1].order[1].opts.method, "GET")
	test.truthy(batches[1].order[1].opts.useragent:find("Mozilla", 1, true) ~= nil, "a browser-like user agent is sent")

	batches[1].order[1].result = { ok = true, status = 200, body = "results" }
	service:step(0)

	test.equal(#responses, 1)
	test.equal(responses[1].status, 200)
	test.equal(responses[1].body, "results")
	test.equal(responses[1].error, nil)
	test.truthy(batches[1].closed, "the multi handle is released when the work is done")
	service:close()
end)

test.it("hands a failed request its error and no status", function()
	local curl, batches = fakeCurl()
	local service = Http.new({ curl = curl })
	local response

	service:request({ url = "https://example.test/", onDone = function(value) response = value end })
	service:step(0)
	batches[1].order[1].result = { ok = false, err = "connection refused" }
	service:step(0)

	test.equal(response.status, 0)
	test.equal(response.error, "connection refused")
	service:close()
end)

test.it("tries a transfer once more as TLS 1.2 when TLS 1.3 cannot connect", function()
	local curl, batches = fakeCurl()
	local service = Http.new({ curl = curl })
	local responses = {}

	service:request({ url = "https://example.test/", onDone = function(value) responses[#responses + 1] = value end })
	service:step(0)
	batches[1].order[1].result = { ok = false, err = "SSL connect error" }
	service:step(0)
	test.equal(#responses, 0, "the handshake failure is not handed to the caller")

	service:step(0)
	local retry = batches[#batches].order[#batches[#batches].order]
	test.equal(retry.url, "https://example.test/", "the same request went out again")
	retry.result = { ok = false, err = "SSL connect error" }
	service:step(0)
	test.equal(#responses, 1, "a second failure is the caller's")
	test.equal(responses[1].error, "SSL connect error")

	service:request({ url = "https://example.test/other", onDone = function(value) responses[#responses + 1] = value end })
	service:step(0)
	batches[#batches].order[#batches[#batches].order].result = { ok = false, err = "connection refused" }
	service:step(0)
	test.equal(#responses, 2, "a failure that is not a handshake is not retried")
	service:close()
end)

test.it("writes a download to a part file and moves it into place", function()
	local dir = tempDir()
	local target = path.join(dir, "01 - Track.mp3")
	local curl, batches = fakeCurl()
	local service = Http.new({ curl = curl })
	local progress, done

	service:download({ url = "https://example.test/track.mp3", path = target, onProgress = function(received, total) progress = { received, total } end, onDone = function(ok, err) done = { ok, err } end })
	service:step(0)

	local state = batches[1].order[1]
	test.equal(state.opts.path, target .. ".part", "curl writes the part file")
	test.truthy(fs.isfile(target .. ".part"))
	test.falsy(fs.isfile(target), "the final name does not exist before the transfer finishes")

	state.opts.progress(100, 40)
	test.equal(progress[1], 40)
	test.equal(progress[2], 100)

	state.result = { ok = true }
	service:step(0)

	test.truthy(fs.isfile(target), "the finished file is where the caller asked for it")
	test.falsy(fs.isfile(target .. ".part"), "the part file is gone")
	test.equal(done[1], true)
	test.equal(done[2], nil)
	test.equal(fs.read(target), "downloaded bytes")

	removeTree(dir)
	service:close()
end)

test.it("leaves no part file when a download fails", function()
	local dir = tempDir()
	local target = path.join(dir, "01 - Track.mp3")
	local curl, batches = fakeCurl()
	local service = Http.new({ curl = curl })
	local done

	service:download({ url = "https://example.test/track.mp3", path = target, onDone = function(ok, err) done = { ok, err } end })
	service:step(0)
	test.truthy(fs.isfile(target .. ".part"))

	batches[1].order[1].result = { ok = false, err = "the stream ended early" }
	service:step(0)

	test.falsy(fs.isfile(target))
	test.falsy(fs.isfile(target .. ".part"), "a failed download leaves nothing behind")
	test.equal(done[1], false)
	test.equal(done[2], "the stream ended early")

	removeTree(dir)
	service:close()
end)

test.it("fails a download when the server answers with an HTTP error", function()
	local dir = tempDir()
	local target = path.join(dir, "01 - Track.mp3")
	local curl, batches = fakeCurl()
	curl.config.failStatus = 404
	local service = Http.new({ curl = curl })
	local done

	service:download({ url = "https://example.test/expired-stream.mp3", path = target, onDone = function(ok, err) done = { ok, err } end })
	service:step(0)
	test.truthy(fs.isfile(target .. ".part"), "the error body arrived in the part file")

	-- libcurl with FAILONERROR says the transfer failed; the captured status says why.
	batches[1].order[1].result = { ok = false, err = "HTTP response code said error" }
	service:step(0)

	test.falsy(fs.isfile(target))
	test.falsy(fs.isfile(target .. ".part"), "an HTTP error leaves no file behind")
	test.equal(done[1], false)
	test.equal(done[2], "HTTP 404")

	removeTree(dir)
	service:close()
end)

test.it("cancels an active download and removes its part file", function()
	local dir = tempDir()
	local target = path.join(dir, "01 - Track.mp3")
	local curl, batches = fakeCurl()
	local service = Http.new({ curl = curl })
	local finished = false

	local handle = service:download({ url = "https://example.test/track.mp3", path = target, onDone = function() finished = true end })
	service:step(0)
	test.truthy(fs.isfile(target .. ".part"))

	handle:cancel()
	test.falsy(fs.isfile(target .. ".part"), "cancelling drops the partial file")
	test.truthy(batches[1].closed, "the transfer is taken off libcurl")
	service:step(0)
	test.falsy(finished, "a cancelled transfer does not call back")

	removeTree(dir)
	service:close()
end)

test.it("runs at most four transfers and takes the next when a slot frees", function()
	local curl, batches = fakeCurl()
	local service = Http.new({ curl = curl })
	local responses = 0

	for at = 1, 6 do
		service:request({ url = "https://example.test/" .. at, onDone = function() responses = responses + 1 end })
	end

	service:step(0)
	test.equal(#batches[1].order, 4, "four transfers are in flight")
	test.equal(#service.queue, 2, "the rest wait their turn")

	for at = 1, 4 do batches[1].order[at].result = { ok = true, status = 200, body = "" } end
	service:step(0)
	test.equal(responses, 4)
	test.equal(#batches[1].order, 4, "no more than four transfers are on the handle")
	test.equal(#service.queue, 2, "the two waiting transfers are still waiting")

	service:step(0)
	test.equal(#batches[1].order, 6, "the two waiting transfers started after the first four")

	for at = 5, 6 do batches[1].order[at].result = { ok = true, status = 200, body = "" } end
	service:step(0)
	test.equal(responses, 6)
	service:close()
end)

test.it("reports a transport that raises and still cleans up a download", function()
	local dir = tempDir()
	local target = path.join(dir, "01 - Track.mp3")
	local curl, batches = fakeCurl()
	local service = Http.new({ curl = curl })
	local done

	service:download({ url = "https://example.test/track.mp3", path = target, onDone = function(ok, err) done = { ok, err } end })
	service:step(0)
	batches[1].pumpError = "libcurl broke"
	service:step(0)

	test.falsy(fs.isfile(target .. ".part"))
	test.equal(done[1], false)
	test.truthy(done[2] ~= nil and done[2]:find("libcurl broke", 1, true) ~= nil)
	test.truthy(batches[1].closed)

	removeTree(dir)
	service:close()
end)
