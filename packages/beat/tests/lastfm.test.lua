local test = require("lde-test")
local Lastfm = require("beat.app.lastfm")

---@class TestBatch
---@field order table[]
---@field requests table[]
local TestBatch = {}
TestBatch.__index = TestBatch

---@param self TestBatch
---@param url string
---@param opts table
---@return number
function TestBatch:add(url, opts)
	local request = { url = url, opts = opts}
	self.order[#self.order + 1] = request
	self.requests[#self.requests + 1] = request

	return #self.order
end

---@param self TestBatch
---@return number
function TestBatch:pump() return 0 end

function TestBatch:close() end

---@return table curl, table requests
local function fakeCurl()
	local requests = {}

	local curl = {
	batch = function()
		return setmetatable({ order = {}, requests = requests}, TestBatch)
	end,
	}

	return curl, requests
end

---@return beat.Settings
local function testSettings()
	return {
	root = nil,
	theme = "night",
	accent = "lime",
	volume = 0.8,
	isMuted = false,
	sort = "title",
	view = "grid",
	sidebarWidth = 264,
	sidebarCollapsed = false,
	uiScale = 1,
	reduceMotion = false,
	lastfmSessionKey = "",
	lastfmUsername = "",
	lastfmEnabled = true,
	}
end

---@param body string
---@param method string
---@return boolean
local function calls(body, method)
	return body:find("method=" .. method, 1, true) ~= nil
end

---@param requests table
---@param method string
---@return table?
local function requestFor(requests, method)
	for at = #requests, 1, -1 do
			local request = requests[at]
			if request.result == nil and calls(request.opts.body, method) then return request end
		end
end

---@param settings beat.Settings
local function connectedSettings(settings)
	settings.lastfmSessionKey = "session-key"
	settings.lastfmUsername = "listener"
	settings.lastfmEnabled = true
end

test.it("authorizes a desktop session and keeps the returned key", function()
	local settings = testSettings()
	local now = 1000
	local curl, requests = fakeCurl()
	local opened
	local saved = 0
	local toasts = {}

	local client = Lastfm.new(settings, {
	onToast = function(_, tone) toasts[#toasts + 1] = tone end,
	onSave = function() saved = saved + 1 end,
	}, {
	curl = curl,
	apiKey = "api-key",
	apiSecret = "api-secret",
	now = function() return now end,
	openBrowser = function(url) opened = url; return true end,
	})

	test.truthy(client:connect())
	local tokenRequest = requestFor(requests, "auth.getToken")
	test.truthy(tokenRequest ~= nil, "the token request was queued")
	test.truthy(tokenRequest.opts.body:find("api_key=api-key", 1, true) ~= nil)
	test.truthy(tokenRequest.opts.body:find("api_sig=", 1, true) ~= nil)

	tokenRequest.result = { ok = true, status = 200, body = '{"token":"request-token"}'}
	client:update(nil, false, {})

	test.equal(client.state, "waiting")
	test.equal(opened, "https://www.last.fm/api/auth/?api_key=api-key&token=request-token")

	now = 1002
	client:update(nil, false, {})
	local sessionRequest = requestFor(requests, "auth.getSession")
	test.truthy(sessionRequest ~= nil, "the session request was sent after the poll")

	sessionRequest.result = {
	ok = true,
	status = 200,
	body = '{"session":{"name":"listener","key":"session-key"}}',
	}
	client:update(nil, false, {})

	test.equal(client.state, "connected")
	test.equal(settings.lastfmSessionKey, "session-key")
	test.equal(settings.lastfmUsername, "listener")
	test.equal(saved, 1)
	test.equal(toasts[#toasts], "success")

	client:close()
end)

test.it("keeps waiting while Last.fm says the token is not authorized", function()
	local settings = testSettings()
	local now = 1000
	local curl, requests = fakeCurl()
	local client = Lastfm.new(settings, nil, {
	curl = curl,
	apiKey = "api-key",
	apiSecret = "api-secret",
	now = function() return now end,
	openBrowser = function() return true end,
	})

	client:connect()
	local tokenRequest = requestFor(requests, "auth.getToken")
	---@cast tokenRequest table
	tokenRequest.result = { ok = true, status = 200, body = '{"token":"request-token"}'}
	client:update(nil, false, {})

	now = 1002
	client:update(nil, false, {})
	local sessionRequest = requestFor(requests, "auth.getSession")
	---@cast sessionRequest table
	sessionRequest.result = {
	ok = true,
	status = 200,
	body = '{"error":14,"message":"This token has not been authorized"}',
	}
	client:update(nil, false, {})

	test.equal(client.state, "waiting", "an unauthorized token is not a failure")
	test.equal(client.error, nil)

	now = 1005
	client:update(nil, false, {})
	test.truthy(requestFor(requests, "auth.getSession") ~= nil, "the poll continued")

	client:close()
end)

test.it("sends now playing and a scrobble once a track is heard", function()
	local settings = testSettings()
	connectedSettings(settings)

	local curl, requests = fakeCurl()
	local client = Lastfm.new(settings, nil, {
	curl = curl,
	apiKey = "api-key",
	apiSecret = "api-secret",
	now = function() return 1700000100 end,
	})

	local track = {
	id = 4,
	title = "Jóga",
	artist = "Björk",
	album = "Homogenic",
	albumArtist = "Björk",
	number = 2,
	duration = 302,
	}
	---@cast track beat.Track
	local scrobble = {
	trackId = 4,
	title = "Jóga",
	artist = "Björk",
	album = "Homogenic",
	albumArtist = "Björk",
	number = 2,
	duration = 302,
	startedAt = 1700000000,
	}

	client:update(track, true, { scrobble})

	local nowPlaying = requestFor(requests, "track.updateNowPlaying")
	test.truthy(nowPlaying ~= nil, "now playing was sent")
	test.truthy(nowPlaying.opts.body:find("artist=Bj%C3%B6rk", 1, true) ~= nil)
	test.truthy(nowPlaying.opts.body:find("track=J%C3%B3ga", 1, true) ~= nil)

	local scrobbleRequest = requestFor(requests, "track.scrobble")
	test.truthy(scrobbleRequest ~= nil, "the scrobble was sent")
	test.truthy(scrobbleRequest.opts.body:find("artist%5B0%5D=Bj%C3%B6rk", 1, true) ~= nil)
	test.truthy(scrobbleRequest.opts.body:find("timestamp%5B0%5D=1700000000", 1, true) ~= nil)

	scrobbleRequest.result = {
	ok = true,
	status = 200,
	body = '{"scrobbles":{"accepted":"1","ignored":"0"}}',
	}
	nowPlaying.result = { ok = true, status = 200, body = '{"nowplaying":{}}'}
	client:update(track, true, {})

	test.equal(#client.scrobbles, 0)
	test.equal(client.state, "connected")

	client:close()
end)

test.it("does not send when scrobbling is paused", function()
	local settings = testSettings()
	settings.lastfmSessionKey = "session-key"
	settings.lastfmUsername = "listener"
	settings.lastfmEnabled = false
	local curl, requests = fakeCurl()
	local client = Lastfm.new(settings, nil, {
	curl = curl,
	apiKey = "api-key",
	apiSecret = "api-secret",
	now = function() return 100 end,
	})

	local track = {
	id = 1,
	title = "Title",
	artist = "Artist",
	album = "Album",
	albumArtist = "Artist",
	duration = 100,
	}
	---@cast track beat.Track
	local scrobble = {
	trackId = 1,
	title = "Title",
	artist = "Artist",
	album = "Album",
	albumArtist = "Artist",
	duration = 100,
	startedAt = 50,
	}
	---@cast scrobble beat.Scrobble

	client:update(track, true, { scrobble})

	test.equal(#requests, 0, "nothing is sent while paused")
	test.equal(#client.scrobbles, 0, "the play is discarded, not queued for later")

	client:close()
end)
