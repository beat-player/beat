-- Last.fm's REST protocol: signing a call, encoding its form body, and building the parameters
-- for the desktop auth handshake and the two playback services. The network is not here, so the
-- signing and the shapes it signs are testable without a socket.
local json = require("json")
local md5 = require("beat.music.md5")

local lastfm = {}

local API_ROOT = "https://ws.audioscrobbler.com/2.0/"
local AUTH_PAGE = "https://www.last.fm/api/auth/"

--- Which parameters Last.fm does not sign: `format` chooses the response encoding, `callback`
--- wraps it, and `api_sig` is the signature itself.
---@param key string
---@return boolean
local function unsigned(key)
	return key == "format" or key == "callback" or key == "api_sig"
end

--- Percent-encode one form value. Last.fm signs the decoded value, so the signature is computed
--- before this is applied.
---@param value any
---@return string
function lastfm.escape(value)
	return (tostring(value):gsub("[^%w%-%._~]", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

--- The api_sig for a set of parameters: names sorted by ASCII, concatenated as name..value with
--- the shared secret appended, and hashed. `format` and `callback` are not included.
---@param params table<string, any>
---@param secret string
---@return string
function lastfm.sign(params, secret)
	local keys = {}
	for key in pairs(params) do
		if not unsigned(key) then keys[#keys + 1] = key end
	end
	table.sort(keys)

	local parts = {}
	for _, key in ipairs(keys) do
		local value = params[key]
		if value ~= nil then parts[#parts + 1] = key .. tostring(value) end
	end

	return md5.sumhexa(table.concat(parts) .. (secret or ""))
end

--- A signed set of parameters for one method. The returned table includes `api_sig` and
--- `format=json`, so `lastfm.encode` is all a request body needs.
---@param method string
---@param apiKey string
---@param secret string
---@param extra table<string, any>?
---@return table<string, any>
function lastfm.params(method, apiKey, secret, extra)
	---@type table<string, any>
	local params = { method = method, api_key = apiKey}

	if extra ~= nil then
		for key, value in pairs(extra) do
			if value ~= nil then params[key] = value end
		end
	end

	params.api_sig = lastfm.sign(params, secret)
	params.format = "json"

	return params
end

--- The form body Last.fm reads. The parameter order is fixed so a test can compare bodies.
---@param params table<string, any>
---@return string
function lastfm.encode(params)
	local keys = {}
	for key, value in pairs(params) do
		if value ~= nil then keys[#keys + 1] = key end
	end
	table.sort(keys)

	local parts = {}
	for _, key in ipairs(keys) do
		parts[#parts + 1] = lastfm.escape(key) .. "=" .. lastfm.escape(params[key])
	end

	return table.concat(parts, "&")
end

--- Step 1 of desktop authentication: an unauthorized request token.
---@param apiKey string
---@param secret string
---@return table<string, any>
function lastfm.tokenParams(apiKey, secret)
	return lastfm.params("auth.getToken", apiKey, secret)
end

--- The page a person opens to grant the application access to their account.
---@param apiKey string
---@param token string
---@param page string?
---@return string
function lastfm.authUrl(apiKey, token, page)
	return (page or AUTH_PAGE) .. "?api_key=" .. lastfm.escape(apiKey) .. "&token="
	.. lastfm.escape(token)
end

--- Step 3 of desktop authentication: turn an authorized token into a session key.
---@param apiKey string
---@param secret string
---@param token string
---@return table<string, any>
function lastfm.sessionParams(apiKey, secret, token)
	return lastfm.params("auth.getSession", apiKey, secret, { token = token})
end

---@param track beat.Track
---@param extra table<string, any>
local function trackFields(track, extra)
	if track.artist ~= nil and track.artist ~= "" then extra.artist = track.artist end
	if track.title ~= nil and track.title ~= "" then extra.track = track.title end
	if track.album ~= nil and track.album ~= "" then extra.album = track.album end
	if track.albumArtist ~= nil and track.albumArtist ~= "" then extra.albumArtist = track.albumArtist end
	if track.number ~= nil and track.number > 0 then extra.trackNumber = math.floor(track.number) end
	if track.duration ~= nil and track.duration > 0 then
		extra.duration = math.floor(track.duration + 0.5)
	end
end

--- The "started playing" notification. A scrobble is still needed later; this only says what
--- the profile is playing now.
---@param apiKey string
---@param secret string
---@param sessionKey string
---@param track beat.Track
---@return table<string, any>
function lastfm.nowPlayingParams(apiKey, secret, sessionKey, track)
	---@type table<string, any>
	local extra = { sk = sessionKey}
	trackFields(track, extra)

	return lastfm.params("track.updateNowPlaying", apiKey, secret, extra)
end

--- Up to fifty plays as one write request, using Last.fm's array notation. Return the table in
--- the same order the scrobbles are given.
---@param apiKey string
---@param secret string
---@param sessionKey string
---@param scrobbles beat.Scrobble[]
---@return table<string, any>
function lastfm.scrobbleParams(apiKey, secret, sessionKey, scrobbles)
	---@type table<string, any>
	local extra = { sk = sessionKey}

	for index, scrobble in ipairs(scrobbles) do
		local at = index - 1
		extra["artist[" .. at .. "]"] = scrobble.artist
		extra["track[" .. at .. "]"] = scrobble.title
		extra["timestamp[" .. at .. "]"] = math.floor(scrobble.startedAt)

		if scrobble.album ~= nil and scrobble.album ~= "" then
			extra["album[" .. at .. "]"] = scrobble.album
		end
		if scrobble.albumArtist ~= nil and scrobble.albumArtist ~= "" then
			extra["albumArtist[" .. at .. "]"] = scrobble.albumArtist
		end
		if scrobble.number ~= nil and scrobble.number > 0 then
			extra["trackNumber[" .. at .. "]"] = math.floor(scrobble.number)
		end
		if scrobble.duration ~= nil and scrobble.duration > 0 then
			extra["duration[" .. at .. "]"] = math.floor(scrobble.duration + 0.5)
		end
	end

	return lastfm.params("track.scrobble", apiKey, secret, extra)
end

--- A decoded response, or the error Last.fm sent. JSON failures and HTTP errors both become
--- `message`, with `code` only where Last.fm named one.
---@param body string
---@return table<string, any>? value
---@return string? message
---@return number? code
function lastfm.response(body)
	local ok, value = pcall(function()
		return json.decode(body):unpack()
	end)

	if not ok or type(value) ~= "table" then
		return nil, "Last.fm returned a response beat could not read"
	end

	if value.error ~= nil then
		return nil, tostring(value.message or ("Last.fm error " .. tostring(value.error))),
		tonumber(value.error)
	end

	return value
end

lastfm.API_ROOT = API_ROOT
lastfm.AUTH_PAGE = AUTH_PAGE

return lastfm
