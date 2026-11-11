-- The app's outbound network: one libcurl multi handle, pumped once a frame, so a page can search
-- a site or a plugin can download an album without the window waiting for it. Requests and
-- downloads share the same four transfer slots; what comes back is handed to the caller on the
-- ticker's thread, the one every other service and the page run on.
--
-- A download writes to `<path>.part` and is moved into place only when libcurl says the transfer
-- finished, so a failed or cancelled one leaves no half-written file where the library may look
-- for music.
local bit = require("bit")
local ffi = require("ffi")
local fs = require("fs")
local jit = require("jit")
local path = require("path")
local Log = require("beat.log")

local curlOk, curl = pcall(require, "curl-sys")

local MAX_ACTIVE = 4
local REQUEST_TIMEOUT = 30
-- The two libcurl options curl-sys's batch wrapper does not set: a status of 400 or above is an
-- error, and the header callback is where the final status line is read from.
local CURLOPT_FAILONERROR = 45
local CURLOPT_HEADERFUNCTION = 20079
-- The TLS version is pinned rather than left as libcurl's range. Bandcamp's edge refuses the
-- handshake this libcurl and Windows' Schannel make when a range is offered (a 403 from Varnish),
-- and accepts either version on its own. A transfer goes out as TLS 1.3 only, and one that fails to
-- connect that way -- a server without 1.3, or Windows 10's Schannel, which has none -- is tried
-- once more as TLS 1.2.
local CURLOPT_SSLVERSION = 32
local TLS_1_3 = 7
local TLS_1_2 = 6 + bit.lshift(6, 16)
-- A browser-like agent: Bandcamp and other sites answer a request that looks like a script with
-- a challenge or a refusal, and the album art and stream URLs are meant for a browser.
local USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " .. "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

---@class beat.HttpResponse
---@field status number # The HTTP status, or 0 when the transfer failed before one arrived
---@field body string?
---@field error string?

---@class beat.HttpHandle
---@field cancel fun(self: beat.HttpHandle)

---@class beat.HttpRequest
---@field method string?
---@field url string
---@field headers table<string, string>?
---@field body string?
---@field onDone fun(response: beat.HttpResponse)

---@class beat.HttpDownload
---@field url string
---@field path string
---@field onProgress fun(received: number, total: number?)?
---@field onDone fun(ok: boolean, err: string?)?

---@class beat.HttpTransfer
---@field kind "request"|"download"
---@field url string
---@field path string? # Where a download ends up; the transfer writes to `part` until it is done
---@field part string?
---@field opts table # What curl is given: method, headers, body, progress
---@field onDone function
---@field index number? # The transfer's slot in the current batch
---@field cancelled boolean
---@field httpStatus { code: number }? # The last status line libcurl saw for a download
---@field headerCallback ffi.cb? # Freed once libcurl can no longer call it; see `releaseCallback`
---@field tls12 boolean? # Retried as TLS 1.2 after TLS 1.3 could not connect

---@class beat.HttpService
---@field curl table? # libcurl's Lua binding, or a stand-in in a test
---@field batch table? # The multi handle, while there is work
---@field queue beat.HttpTransfer[] # Waiting for a free slot
---@field active beat.HttpTransfer[] # Queued on the batch
local Http = {}
Http.__index = Http

---@param deps { curl: table? }?
---@return beat.HttpService
function Http.new(deps)
	deps = deps or {}
	-- `rawget`: a service's deps table answers a key it was not given with an error, and the
	-- stand-in is only there when a test hands it over.
	local seam = rawget(deps, "curl")
	return setmetatable({ curl = seam or (curlOk and curl or nil), batch = nil, queue = {}, active = {} }, Http)
end

-- The libcurl handle curl-sys opened. Its batch wrapper exposes neither FAILONERROR nor the
-- response code, so a download needs the two options set on the easy handle it already queued.
-- `false` means the library could not be opened again; downloads still run, just without the
-- status check.
local curlLib = nil

---@return any?
local function libcurl()
	if curlLib ~= nil then return curlLib or nil end

	local name = jit.os == "Windows" and "curl.dll" or (jit.os == "OSX" and "libcurl.dylib" or "libcurl.so")
	local candidates = {}
	local found = package.searchpath ~= nil and package.searchpath("curl-sys", package.path) or nil
	if found ~= nil then
		local here = found:match("^(.*)[/\\]") or ""
		candidates[#candidates + 1] = here .. "/" .. name
	end
	candidates[#candidates + 1] = name
	candidates[#candidates + 1] = name:gsub("%.dll$", ""):gsub("%.so$", ""):gsub("%.dylib$", "")

	for _, candidate in ipairs(candidates) do
		local ok, lib = pcall(ffi.load, candidate)
		if ok then
			curlLib = lib
			return lib
		end
	end

	curlLib = false
	return nil
end

--- Sets a download's easy handle to fail on an HTTP error and records the last status line it
--- sees, so a 404 is reported as `HTTP 404` rather than saved as a file. A batch from a test has
--- no easy handle; it can hand over `httpStatus` instead.
---@param transfer beat.HttpTransfer
---@param state table
---@return boolean watched # False when the status cannot be seen, so an HTTP download is refused
local function attachStatus(transfer, state)
	local watched = false

	if state.easy ~= nil and type(state.easy) == "cdata" then
		local lib = libcurl()
		if lib ~= nil then
			local captured = { code = 0 }
			local callback = ffi.cast("curl_write_callback", function(ptr, size, nmemb)
				local line = ffi.string(ptr, size * nmemb)
				local code = line:match("^HTTP/[%d%.]+%s+(%d+)")
				if code ~= nil then captured.code = tonumber(code) end
				return size * nmemb
			end)

			local ok = pcall(function()
				lib.curl_easy_setopt(state.easy, CURLOPT_HEADERFUNCTION, callback)
				lib.curl_easy_setopt(state.easy, CURLOPT_FAILONERROR, ffi.cast("long", 1))
			end)
			if ok then
				transfer.headerCallback = callback
				transfer.httpStatus = captured
				watched = true
			else
				callback:free()
			end
		end
	end

	if state.httpStatus ~= nil then
		transfer.httpStatus = { code = state.httpStatus }
		watched = true
	end

	return watched
end

--- Frees a download's header callback once libcurl can no longer call it: its easy handle has
--- finished or its batch is closed. LuaJIT has room for only so many C callbacks and never takes
--- one back on its own, so keeping them made a long run of downloads fail with "too many
--- callbacks". A transfer that starts again gets a new one from `attachStatus`.
---@param transfer beat.HttpTransfer
local function releaseCallback(transfer)
	if transfer.headerCallback == nil then return end
	transfer.headerCallback:free()
	transfer.headerCallback = nil
end

--- Pins the TLS version of a transfer's easy handle; see `CURLOPT_SSLVERSION` above. A batch from a
--- test has no easy handle, and nothing to pin.
---@param transfer beat.HttpTransfer
---@param state table
local function pinTls(transfer, state)
	if state.easy == nil or type(state.easy) ~= "cdata" then return end
	local lib = libcurl()
	if lib == nil then return end
	pcall(lib.curl_easy_setopt, state.easy, CURLOPT_SSLVERSION, ffi.cast("long", transfer.tls12 and TLS_1_2 or TLS_1_3))
end

--- Whether a failure is a TLS handshake that a pinned TLS 1.2 might get past.
---@param err any
---@return boolean
local function tlsFailure(err)
	return type(err) == "string" and (err:find("SSL", 1, true) ~= nil or err:find("TLS", 1, true) ~= nil or err:find(
		"built-in",
		1,
		true
	) ~= nil)
end

---@param service beat.HttpService
---@param transfer beat.HttpTransfer
---@return beat.HttpHandle
local function handleFor(service, transfer)
	local handle = {}
	function handle:cancel()
		service:cancel(transfer)
	end
	return handle
end

---@param transfer beat.HttpTransfer
---@return boolean
local function isDownload(transfer)
	return transfer.kind == "download"
end

--- A final status that means the server refused the download. 0 is a protocol with no status,
--- such as `file://`, which is still a finished transfer.
---@param code number
---@return boolean
local function badStatus(code)
	return code ~= 0 and (code < 200 or code >= 400)
end

--- Removes a transfer from the active list without touching the batch. A callback may cancel
--- another transfer, so the list is searched rather than assumed to hold the one being finished.
---@param self beat.HttpService
---@param transfer beat.HttpTransfer
---@return boolean removed
function Http:forgetActive(transfer)
	for at, candidate in ipairs(self.active) do
		if candidate == transfer then
			table.remove(self.active, at)
			return true
		end
	end
	return false
end

---@param self beat.HttpService
---@param transfer beat.HttpTransfer
function Http:removeQueued(transfer)
	for at, candidate in ipairs(self.queue) do
		if candidate == transfer then
			table.remove(self.queue, at)
			return
		end
	end
end

--- libcurl is holding the file open, so the partial file can only be removed after the batch is
--- closed. Everything still wanted goes back to the front of the queue and starts again.
---@param self beat.HttpService
function Http:restartBatch()
	if self.batch == nil then return end
	self.batch:close()
	self.batch = nil

	local waiting = self.active
	self.active = {}
	for at = #waiting, 1, -1 do
		local transfer = waiting[at]
		transfer.index = nil
		releaseCallback(transfer)
		table.insert(self.queue, 1, transfer)
	end
end

---@param self beat.HttpService
---@param transfer beat.HttpTransfer
function Http:cancel(transfer)
	if transfer.cancelled then return end
	transfer.cancelled = true

	if self:forgetActive(transfer) then
		self:restartBatch()
	else
		self:removeQueued(transfer)
	end
	-- The batch it was on is closed by now, or it never reached one.
	releaseCallback(transfer)

	if isDownload(transfer) and transfer.part ~= nil then fs.delete(transfer.part) end
end

---@param self beat.HttpService
---@return boolean
---@return string? err
function Http:openBatch()
	if self.curl == nil then return false, "curl-sys is not available" end
	local ok, batch, err = pcall(self.curl.batch)
	if not ok then return false, tostring(batch) end
	if batch == nil then return false, err or "curl-sys could not start" end
	self.batch = batch
	return true
end

---@param callback function
---@param ... any
local function call(callback, ...)
	local ok, err = pcall(callback, ...)
	if not ok then Log.write("error", "an http callback failed: " .. tostring(err)) end
end

---@param self beat.HttpService
---@param transfer beat.HttpTransfer
---@param result table
function Http:finish(transfer, result)
	if transfer.cancelled then
		if isDownload(transfer) and transfer.part ~= nil then fs.delete(transfer.part) end
		return
	end
	if result.ok ~= true and not transfer.tls12 and tlsFailure(result.err) then
		transfer.tls12 = true
		transfer.index = nil
		table.insert(self.queue, 1, transfer)
		return
	end

	if not isDownload(transfer) then
		if result.ok == true then
			call(transfer.onDone, { status = tonumber(result.status) or 0, body = result.body })
		else
			call(transfer.onDone, { status = 0, error = type(result.err) == "string" and result.err or "network error" })
		end
		return
	end

	---@cast transfer beat.HttpTransfer
	local status = transfer.httpStatus ~= nil and transfer.httpStatus.code or 0
	if result.ok == true and not badStatus(status) then
		local moved, moveErr = fs.move(transfer.part --[[@as string]],  transfer.path --[[@as string]] )
		if moved then
			call(transfer.onDone, true)
		else
			fs.delete(transfer.part --[[@as string]] )
			call(transfer.onDone, false, moveErr or "could not move the download into place")
		end
	else
		fs.delete(transfer.part --[[@as string]] )
		if badStatus(status) then
			call(transfer.onDone, false, "HTTP " .. status)
		else
			call(transfer.onDone, false, type(result.err) == "string" and result.err or "download failed")
		end
	end
end

---@param self beat.HttpService
---@param transfer beat.HttpTransfer
---@return boolean
function Http:add(transfer)
	if self.batch == nil then
		local ok, err = self:openBatch()
		if not ok then
			if isDownload(transfer) and transfer.part ~= nil then fs.delete(transfer.part) end
			if not isDownload(transfer) then
				call(transfer.onDone, { status = 0, error = err })
			else
				call(transfer.onDone, false, err)
			end
			return false
		end
	end

	local ok, index = pcall(self.batch.add, self.batch, transfer.url, transfer.opts)
	if not ok or type(index) ~= "number" then
		if isDownload(transfer) and transfer.part ~= nil then fs.delete(transfer.part) end
		local err = tostring(index)
		if not isDownload(transfer) then
			call(transfer.onDone, { status = 0, error = err })
		else
			call(transfer.onDone, false, err)
		end
		return false
	end

	transfer.index = index
	pinTls(transfer, self.batch.order and self.batch.order[index] or {})
	if isDownload(transfer) then
		local state = self.batch.order and self.batch.order[index]
		local ok, watched = pcall(attachStatus, transfer, state or {})
		if not ok then
			Log.write("error", "a download's status could not be watched: " .. tostring(watched))
			watched = false
		end
		-- Saving a server's error page as an album track is worse than not downloading it: an
		-- HTTP download whose status cannot be seen is refused, and a protocol without a status
		-- (`file://`) still runs.
		if not watched and transfer.url:match("^https?://") ~= nil then
			transfer.cancelled = true
			self:restartBatch()
			releaseCallback(transfer)
			fs.delete(transfer.part --[[@as string]] )
			call(transfer.onDone, false, "could not check the download's HTTP status")
			return false
		end
	end
	self.active[#self.active + 1] = transfer
	return true
end

---@param self beat.HttpService
function Http:close()
	local parts = {}
	for _, transfer in ipairs(self.queue) do
		transfer.cancelled = true
		if isDownload(transfer) and transfer.part ~= nil then parts[#parts + 1] = transfer.part end
	end
	for _, transfer in ipairs(self.active) do
		transfer.cancelled = true
		if isDownload(transfer) and transfer.part ~= nil then parts[#parts + 1] = transfer.part end
	end
	local closing = self.active
	self.queue = {}
	self.active = {}

	if self.batch ~= nil then
		self.batch:close()
		self.batch = nil
	end
	for _, transfer in ipairs(closing) do releaseCallback(transfer) end
	for _, part in ipairs(parts) do fs.delete(part) end
end

--- A request whose answer is the whole body. `onDone` runs once, on the ticker.
---@param request beat.HttpRequest
---@return beat.HttpHandle
function Http:request(request)
	if type(request) ~= "table" then error("http:request needs a table", 0) end
	if type(request.url) ~= "string" then error("http:request needs a url", 0) end
	if type(request.onDone) ~= "function" then error("http:request needs onDone(response)", 0) end

	local method = request.method or "GET"
	if type(method) ~= "string" then error("a request's method must be a string", 0) end

	---@type beat.HttpTransfer
	local transfer = {
		kind = "request",
		url = request.url,
		opts = {
			method = method:upper(),
			headers = request.headers,
			body = request.body,
			timeout = REQUEST_TIMEOUT,
			useragent = USER_AGENT
		},
		onDone = request.onDone,
		cancelled = false
	}

	self.queue[#self.queue + 1] = transfer
	return handleFor(self, transfer)
end

--- A download to `path`. The bytes arrive in `<path>.part` and are moved over `path` only when the
--- transfer finishes; `onProgress` is given what libcurl knows, which is no total until the
--- response headers have arrived.
---@param download beat.HttpDownload
---@return beat.HttpHandle
function Http:download(download)
	if type(download) ~= "table" then error("http:download needs a table", 0) end
	if type(download.url) ~= "string" then error("http:download needs a url", 0) end
	if type(download.path) ~= "string" then error("http:download needs a path", 0) end
	if type(download.onDone) ~= "function" then error("http:download needs onDone(ok, err)", 0) end

	local part = download.path .. ".part"
	fs.mkdirAll(path.dirname(download.path))

	local onProgress = download.onProgress
	---@type beat.HttpTransfer
	local transfer = {
		kind = "download",
		url = download.url,
		path = download.path,
		part = part,
		opts = {
			path = part,
			useragent = USER_AGENT,
			progress = onProgress ~= nil and function(dlTotal, dlNow)
				call(onProgress, dlNow, dlTotal > 0 and dlTotal or nil)
				return nil
			end or nil
		},
		onDone = download.onDone,
		cancelled = false
	}

	self.queue[#self.queue + 1] = transfer
	return handleFor(self, transfer)
end

--- Pumps the batch. libcurl calls back into Lua -- the body, the progress, a download's status
--- line -- from inside `curl_multi_perform`, and LuaJIT cannot take a callback from C that compiled
--- code called: once the app's tick loop is hot enough to be compiled through to here, the first
--- callback panics the process ("bad callback"). This function, and so the call into C, stays in
--- the interpreter.
---@param batch table
local function pump(batch)
	return batch:pump()
end
jit.off(pump)

--- Moves waiting transfers onto the batch, pumps it, and hands finished ones to their callbacks.
---@param _now number
---@return boolean changed
---@return boolean busy
function Http:step(_now)
	local changed = false

	while #self.active < MAX_ACTIVE and #self.queue > 0 do
		local transfer = table.remove(self.queue, 1)
		if not transfer.cancelled then
			if self:add(transfer) then changed = true end
		end
	end

	if self.batch ~= nil and #self.active > 0 then
		local ok, err = pcall(pump, self.batch)
		if not ok then
			local batch = self.batch
			self.batch = nil
			pcall(batch.close, batch)
			local transfers = self.active
			self.active = {}
			for _, transfer in ipairs(transfers) do
				releaseCallback(transfer)
				self:finish(transfer, { ok = false, err = tostring(err) })
			end
			changed = true
		else
			-- Take the finished ones out before any callback runs: a callback may cancel another
			-- transfer, which restarts the batch, and a finished transfer must not be queued again.
			local done = {}
			for _, transfer in ipairs(self.active) do
				local index = transfer.index --[[@as number]]
				local state = self.batch.order and self.batch.order[index]
				local result = state and state.result
				if result ~= nil then done[#done + 1] = { transfer = transfer, result = result } end
			end
			-- The batch has cleaned up a finished transfer's handle, so its callback is done with.
			for _, entry in ipairs(done) do
				self:forgetActive(entry.transfer)
				releaseCallback(entry.transfer)
			end
			for _, entry in ipairs(done) do self:finish(entry.transfer, entry.result) end
			if #done > 0 then changed = true end
		end
	end

	if self.batch ~= nil and #self.active == 0 and #self.queue == 0 then
		self.batch:close()
		self.batch = nil
		changed = true
	end

	return changed, self.batch ~= nil or #self.queue > 0
end

return Http
