-- Last.fm's desktop authentication and playback services.
--
-- The transport is libcurl's multi interface, pumped once a frame: no request blocks the window,
-- and several calls can be in flight while the screen keeps drawing. The app's API account is
-- compiled in; what the settings it is handed own is the per-listener session key, so a save from
-- here is the same save the settings screen makes.
local protocol = require("beat.app.services.lastfm.protocol")
local credentials = require("beat.app.services.lastfm.credentials")

local curlOk, curl = pcall(require, "curl-sys")

local API_ROOT = protocol.API_ROOT
local AUTH_PAGE = protocol.AUTH_PAGE
local USER_AGENT = "beat/0.1.0"
local REQUEST_TIMEOUT = 15
local AUTH_POLL = 3
local AUTH_LIFETIME = 60 * 60
local SCROBBLE_BATCH = 50
local SCROBBLE_LIMIT = 512
local RETRY_INTERVAL = 60
local RATE_LIMIT_RETRY = 120

---@param value string?
---@return string
local function trim(value)
	return (value or ""):match("^%s*(.-)%s*$")
end

---@class beat.LastfmHandlers
---@field onToast fun(text: string, tone: string?)? # What the app says when auth or a scrobble fails
---@field onSave fun()? # Persist settings after a session key arrives or is cleared

---@class beat.LastfmClient
---@field settings beat.Settings
---@field handlers beat.LastfmHandlers
---@field apiKey string
---@field apiSecret string
---@field now fun(): number
---@field apiRoot string
---@field authPage string
---@field openBrowser fun(url: string): boolean
---@field curl table?
---@field batch table?
---@field pending table<number, { kind: string, onDone: fun(value: table?, err: string?, code: number?) }>
---@field pendingCount number
---@field state "idle"|"token"|"waiting"|"connected"|"error"
---@field token string?
---@field authUrl string?
---@field error string?
---@field authInFlight boolean
---@field authEpoch number
---@field nextAuthPoll number
---@field authStartedAt number
---@field scrobbles beat.Scrobble[]
---@field scrobbling boolean
---@field scrobbleError string?
---@field retryAt number
---@field nowPlayingTrackId number?
local Client = {}
Client.__index = Client

---@class beat.LastfmOptions
---@field now fun(): number?
---@field apiRoot string?
---@field authPage string?
---@field apiKey string?
---@field apiSecret string?
---@field openBrowser fun(url: string): boolean?
---@field curl table?

---@param settings beat.Settings
---@param handlers beat.LastfmHandlers?
---@param opts beat.LastfmOptions?
---@return beat.LastfmClient
local function new(settings, handlers, opts)
	opts = opts or {}
	local self = setmetatable({
		settings = settings,
		handlers = handlers or {},
		apiKey = trim(opts.apiKey or credentials.apiKey),
		apiSecret = trim(opts.apiSecret or credentials.apiSecret),
		now = opts.now or os.time,
		apiRoot = opts.apiRoot or API_ROOT,
		authPage = opts.authPage or AUTH_PAGE,
		-- What opens the authorization page comes from outside: the client is the network, not the
		-- desktop. A caller that leaves it out simply cannot open one.
		openBrowser = opts.openBrowser or function() return false end,
		curl = opts.curl or (curlOk and curl or nil),
		batch = nil,
		pending = {},
		pendingCount = 0,
		state = "idle",
		token = nil,
		authUrl = nil,
		error = nil,
		authInFlight = false,
		authEpoch = 0,
		nextAuthPoll = 0,
		authStartedAt = 0,
		scrobbles = {},
		scrobbling = false,
		scrobbleError = nil,
		retryAt = 0,
		nowPlayingTrackId = nil,
	}, Client)

	if trim(settings.lastfmSessionKey) ~= "" and self.apiKey ~= "" and self.apiSecret ~= "" then
		self.state = "connected"
	end

	self:newBatch()
	return self
end

---@return boolean
function Client:newBatch()
	if self.curl == nil then
		self.batch = nil
		self.error = self.error or "curl-sys is not available"
		return false
	end

	local batch, err = self.curl.batch()
	if batch == nil then
		self.batch = nil
		self.error = err or "curl-sys could not start"
		return false
	end

	---@cast batch table
	self.batch = batch
	return true
end

---@param text string
---@param tone string?
function Client:notify(text, tone)
	local handler = self.handlers.onToast
	if handler ~= nil then handler(text, tone) end
end

function Client:persist()
	local handler = self.handlers.onSave
	if handler ~= nil then handler() end
end

---@return boolean
function Client:isConnected()
	return self.state == "connected" and trim(self.settings.lastfmSessionKey) ~= ""
end

---@return boolean
function Client:isAuthorizing()
	return self.state == "token" or self.state == "waiting"
end

---@return boolean
function Client:isBusy()
	local flushing = self.batch ~= nil and self.state == "connected"
	and self.settings.lastfmEnabled ~= false and #self.scrobbles > 0
	return self.pendingCount > 0 or self.scrobbling or flushing
end

---@return string
function Client:statusText()
	if self.state == "connected" then
		local name = trim(self.settings.lastfmUsername)
		return name ~= "" and ("Connected as " .. name) or "Connected to Last.fm"
	elseif self.state == "waiting" then
		return "Waiting for authorization in your browser…"
	elseif self.state == "token" then
		return "Requesting a Last.fm authorization token…"
	elseif self.error ~= nil then
		return self.error
	end

	return "Not connected"
end

---@return "success"|"danger"|"muted"
function Client:statusTone()
	if self.state == "connected" then return "success" end
	if self.error ~= nil then return "danger" end
	return "muted"
end

---@param kind string
---@param params table<string, any>
---@param onDone fun(value: table?, err: string?, code: number?)
---@return boolean
---@return string?
function Client:send(kind, params, onDone)
	if self.batch == nil then return false, self.error or "Last.fm network is unavailable" end

	local ok, index = pcall(self.batch.add, self.batch, self.apiRoot, {
		method = "POST",
		body = protocol.encode(params),
		timeout = REQUEST_TIMEOUT,
		useragent = USER_AGENT,
		headers = { ["Content-Type"] = "application/x-www-form-urlencoded"},
	})
	if not ok or type(index) ~= "number" then return false, tostring(index) end

	self.pending[index] = { kind = kind, onDone = onDone}
	self.pendingCount = self.pendingCount + 1
	return true
end

---@param result table
---@return table? value
---@return string? err
---@return number? code
local function resultOf(result)
	if result.ok ~= true then
		local failure = result.err
		if type(failure) ~= "string" then failure = "Last.fm network error" end
		return nil, failure, nil
	end

	local body = result.body
	if type(body) ~= "string" then body = "" end
	local value, err, code = protocol.response(body)
	---@cast value table?
	---@cast err string?
	---@cast code number?
	if value ~= nil then return value, nil, nil end
	if code ~= nil then return nil, err, code end
	local status = tonumber(result.status) or 0
	if status ~= 200 then return nil, "Last.fm returned HTTP " .. tostring(status), status end

	return nil, err, nil
end

---@param message string
function Client:failPending(message)
	local pending = self.pending
	self.pending = {}
	self.pendingCount = 0

	if self.batch ~= nil then
		self.batch:close()
		self.batch = nil
	end

	self:newBatch()
	for _, item in pairs(pending) do item.onDone(nil, message) end
end

--- Pump the multi handle and run the callbacks of every transfer that finished.
---@return boolean changed
function Client:pump()
	if self.pendingCount == 0 or self.batch == nil then return false end

	local batch = self.batch
	local ok, running = pcall(batch.pump, batch)
	if not ok then
		self:failPending(tostring(running))
		return true
	end

	local done = {}
	for index, item in pairs(self.pending) do
		local state = batch.order and batch.order[index]
		local result = state and state.result
		if result ~= nil then done[#done + 1] = { index = index, item = item, result = result} end
	end

	table.sort(done, function(a, b) return a.index < b.index end)

	for _, entry in ipairs(done) do
		self.pending[entry.index] = nil
		self.pendingCount = self.pendingCount - 1
		local value, err, code = resultOf(entry.result)
		entry.item.onDone(value, err, code)
	end

	if self.pendingCount == 0 and self.batch == batch then
		batch:close()
		self:newBatch()
	end

	return #done > 0
end

---@param message string
function Client:failAuth(message)
	self.state = "error"
	self.error = message
	self.token = nil
	self.authUrl = nil
	self.authInFlight = false
	self:notify("Last.fm: " .. message, "error")
end

--- Step 1 and 2 of desktop authentication: get a token, then send the person to Last.fm.
---@return boolean
function Client:connect()
	if self.curl == nil then
		self:failAuth(self.error or "curl-sys is not available")
		return false
	end
	if self.state == "token" or self.state == "waiting" then return false end

	if self.apiKey == "" or self.apiSecret == "" then
		self:failAuth("this build has no Last.fm app credentials")
		return false
	end

	local apiKey, secret = self.apiKey, self.apiSecret

	self.authEpoch = self.authEpoch + 1
	local epoch = self.authEpoch
	self.error = nil
	self.token = nil
	self.authUrl = nil
	self.authStartedAt = self.now()
	self.state = "token"

	local ok, err = self:send("token", protocol.tokenParams(apiKey, secret),
	function(value, message)
		if epoch ~= self.authEpoch then return end
		if message ~= nil then
			self:failAuth(message)
			return
		end

		local token = value and value.token
		if type(token) ~= "string" or token == "" then
			self:failAuth("Last.fm did not return an authorization token")
			return
		end

		self.token = token
		self.authUrl = protocol.authUrl(apiKey, token, self.authPage)
		self.state = "waiting"
		self.nextAuthPoll = self.now() + 2

		local opened = false
		local okOpen, result = pcall(self.openBrowser, self.authUrl)
		if okOpen then opened = result ~= false end
		if opened then
			self:notify("Authorize beat in your browser, then return here")
		else
			self:notify("Could not open a browser; use the Last.fm authorization page", "error")
		end
	end)

	if not ok then self:failAuth(err or "could not start authorization") end
	return ok
end

---@return boolean
function Client:openAuthPage()
	if self.authUrl == nil then return false end
	local ok, result = pcall(self.openBrowser, self.authUrl)
	return ok and result ~= false
end

--- Ask again whether the person has authorized the token. Code 14 means not yet.
---@param now number
---@return boolean
function Client:poll(now)
	if self.state ~= "waiting" or self.authInFlight then return false end
	if now < self.nextAuthPoll then return false end
	if self.authStartedAt > 0 and now - self.authStartedAt > AUTH_LIFETIME then
		self:failAuth("the authorization token expired; try connecting again")
		return true
	end

	local apiKey, secret = self.apiKey, self.apiSecret
	if apiKey == "" or secret == "" or self.token == nil then
		self:failAuth("the app credentials are missing")
		return true
	end

	self.nextAuthPoll = now + AUTH_POLL
	self.authInFlight = true
	local epoch = self.authEpoch

	local ok, err = self:send("session", protocol.sessionParams(apiKey, secret, self.token),
	function(value, message, code)
		self.authInFlight = false
		if epoch ~= self.authEpoch then return end

		if message ~= nil then
			if code == 14 then return end
			self:failAuth(code == 15 and "the authorization token expired; try connecting again"
			or message)
			return
		end

		local session = value and value.session
		local sessionKey = type(session) == "table" and session.key or nil
		if type(sessionKey) ~= "string" or sessionKey == "" then
			self:failAuth("Last.fm did not return a session key")
			return
		end

		self.settings.lastfmSessionKey = sessionKey
		self.settings.lastfmUsername = type(session.name) == "string" and session.name or ""
		self.state = "connected"
		self.token = nil
		self.authUrl = nil
		self.error = nil
		self.authInFlight = false
		self.nowPlayingTrackId = nil
		self:persist()
		self:notify("Connected to Last.fm as "
		.. (trim(self.settings.lastfmUsername) ~= "" and self.settings.lastfmUsername
		or "your account"), "success")
	end)

	if not ok then
		self.authInFlight = false
		if epoch == self.authEpoch then self:failAuth(err or "could not check authorization") end
	end
	return true
end

function Client:cancelAuth()
	if not self:isAuthorizing() then return end

	self.authEpoch = self.authEpoch + 1
	self.state = trim(self.settings.lastfmSessionKey) ~= "" and "connected" or "idle"
	self.token = nil
	self.authUrl = nil
	self.error = nil
	self.authInFlight = false
end

---@param chunk beat.Scrobble[]
function Client:requeue(chunk)
	for at = #chunk, 1, -1 do table.insert(self.scrobbles, 1, chunk[at]) end

	local over = #self.scrobbles - SCROBBLE_LIMIT
	for _ = 1, math.max(0, over) do table.remove(self.scrobbles, 1) end
end

function Client:expireSession()
	if trim(self.settings.lastfmSessionKey) == "" then return end

	self.settings.lastfmSessionKey = ""
	self.settings.lastfmUsername = ""
	self.state = "idle"
	self.error = nil
	self.nowPlayingTrackId = nil
	self.scrobbleError = nil
	self:persist()
	self:notify("Last.fm session expired; connect again in Settings", "error")
end

---@return boolean
function Client:flush()
	if #self.scrobbles == 0 then return false end

	local chunk = {}
	local count = math.min(SCROBBLE_BATCH, #self.scrobbles)
	for at = 1, count do chunk[at] = self.scrobbles[at] end
	for _ = 1, count do table.remove(self.scrobbles, 1) end

	local apiKey, secret = self.apiKey, self.apiSecret
	local sessionKey = trim(self.settings.lastfmSessionKey)

	self.scrobbling = true
	local ok, err = self:send("scrobble",
	protocol.scrobbleParams(apiKey, secret, sessionKey, chunk),
	function(value, message, code)
		self.scrobbling = false

		if message ~= nil then
			if self.state == "connected" and trim(self.settings.lastfmSessionKey) == sessionKey then
				self:requeue(chunk)
			end
			if code == 9 then
				self.scrobbleError = nil
				self:expireSession()
				return
			end
			if code == 29 then
				self.retryAt = self.now() + RATE_LIMIT_RETRY
				return
			end

			self.retryAt = self.now() + RETRY_INTERVAL
			if self.scrobbleError ~= message then
				self.scrobbleError = message
				self:notify("Last.fm scrobble failed: " .. message, "error")
			end
			return
		end

		self.scrobbleError = nil
		self.retryAt = 0
		local scrobbles = value and value.scrobbles
		local ignored = tonumber(scrobbles and scrobbles.ignored) or 0
		if ignored > 0 then
			self:notify(tostring(ignored) .. " Last.fm scrobble(s) were ignored", "error")
		end
	end)

	if not ok then
		self.scrobbling = false
		self:requeue(chunk)
		self.retryAt = self.now() + RETRY_INTERVAL
		if self.error == nil then self.error = err end
	end

	return true
end

---@param scrobbles beat.Scrobble[]
function Client:enqueue(scrobbles)
	for _, scrobble in ipairs(scrobbles) do
		if #self.scrobbles >= SCROBBLE_LIMIT then table.remove(self.scrobbles, 1) end
		self.scrobbles[#self.scrobbles + 1] = scrobble
	end
end

---@param track beat.Track
function Client:sendNowPlaying(track)
	self.nowPlayingTrackId = track.id
	local apiKey, secret = self.apiKey, self.apiSecret
	local sessionKey = trim(self.settings.lastfmSessionKey)
	if apiKey == "" or secret == "" or sessionKey == "" then
		self:expireSession()
		return
	end

	self:send("nowPlaying", protocol.nowPlayingParams(apiKey, secret, sessionKey, track),
	function(_, message, code)
		if message ~= nil and code == 9 then self:expireSession() end
	end)
end

--- What the app calls once a frame: pump the network, poll a pending authorization, and keep
--- Last.fm told what is playing and what has been heard.
---@param track beat.Track?
---@param playing boolean
---@param scrobbles beat.Scrobble[]
---@return boolean changed
function Client:update(track, playing, scrobbles)
	scrobbles = scrobbles or {}
	local changed = self:pump()

	if self.state == "waiting" then
		if self:poll(self.now()) then changed = true end
	end

	if track == nil then self.nowPlayingTrackId = nil end

	if self.state ~= "connected" or self.settings.lastfmEnabled == false then
		return changed
	end

	if #scrobbles > 0 then
		self:enqueue(scrobbles)
		changed = true
	end

	if playing and track ~= nil and track.id ~= self.nowPlayingTrackId then
		self:sendNowPlaying(track)
		changed = true
	end

	if #self.scrobbles > 0 and not self.scrobbling and self.now() >= self.retryAt then
		if self:flush() then changed = true end
	end

	return changed
end

function Client:disconnect()
	self.authEpoch = self.authEpoch + 1
	self.authInFlight = false
	self.token = nil
	self.authUrl = nil
	self.error = nil
	self.state = "idle"
	self.nowPlayingTrackId = nil
	self.scrobbling = false
	self.scrobbleError = nil
	self.scrobbles = {}
	self.retryAt = 0
	self.settings.lastfmSessionKey = ""
	self.settings.lastfmUsername = ""

	if self.batch ~= nil then
		self.batch:close()
		self.batch = nil
	end
	self.pending = {}
	self.pendingCount = 0
	self:newBatch()

	self:persist()
	self:notify("Disconnected from Last.fm")
end

--- Release the curl multi handle. The app calls this when it is rebuilt, so a test that makes
--- many apps does not keep a libcurl handle per app alive.
function Client:close()
	if self.batch ~= nil then
		self.batch:close()
		self.batch = nil
	end
	self.pending = {}
	self.pendingCount = 0
	self.authInFlight = false
	self.scrobbling = false
end

return { new = new}
