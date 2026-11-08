local test = require("lde-test")
local md5 = require("beat.music.md5")
local lastfm = require("beat.app.services.lastfm.protocol")

--- A complete track, as the scanner would hand it over.
---@param overrides { title: string, album: string, albumArtist: string, number: number?, duration: number }
---@return beat.Track
local function track(overrides)
	---@type beat.Track
	return {
		id = 1,
		path = "/music/" .. overrides.title .. ".flac",
		title = overrides.title,
		artist = "Artist",
		album = overrides.album,
		albumId = 1,
		artistId = 1,
		albumArtist = overrides.albumArtist,
		disc = 1,
		number = overrides.number,
		duration = overrides.duration,
		format = "FLAC",
		sampleRate = 44100,
		channels = 2,
		hasPicture = false,
		modified = 0,
		hash = "hash-" .. overrides.title,
	}
end

test.it("hashes the RFC 1321 vectors", function()
	test.equal(md5.sumhexa(""), "d41d8cd98f00b204e9800998ecf8427e")
	test.equal(md5.sumhexa("abc"), "900150983cd24fb0d6963f7d28e17f72")
	test.equal(md5.sumhexa("message digest"), "f96b697d7cb7938d525a2f31aaf161d0")
end)

test.it("signs the example from the Last.fm authentication docs", function()
	local params = {
		api_key = "xxxxxxxx",
		method = "auth.getSession",
		token = "xxxxxxx",
		format = "json",
	}
	test.equal(lastfm.sign(params, "mysecret"), "68afb32bee072407a63b6c41f3e1e2b4")
end)

test.it("sorts parameter names by ASCII when signing", function()
	local params = {}
	params["artist[10]"] = "Ten"
	params["artist[2]"] = "Two"
	params.method = "track.scrobble"
	params.api_key = "key"

	test.equal(lastfm.sign(params, "secret"), md5.sumhexa(
	"api_keykeyartist[10]Tenartist[2]Two" .. "methodtrack.scrobble" .. "secret"))
end)

test.it("encodes a form body without signing the response format", function()
	local params = lastfm.params("track.updateNowPlaying", "key", "secret", {
		artist = "Björk",
		track = "Jóga",
	})
	local body = lastfm.encode(params)

	test.truthy(body:find("format=json", 1, true) ~= nil)
	test.truthy(body:find("artist=Bj%C3%B6rk", 1, true) ~= nil)
	test.truthy(body:find("track=J%C3%B3ga", 1, true) ~= nil)
	test.equal(params.api_sig, md5.sumhexa("api_keykeyartistBjörkmethodtrack.updateNowPlaying"
	.. "trackJóga" .. "secret"))
end)

test.it("builds desktop authentication parameters and URL", function()
	local token = lastfm.tokenParams("key", "secret")
	test.equal(token.method, "auth.getToken")
	test.equal(token.api_key, "key")
	test.equal(token.format, "json")
	test.equal(token.api_sig, md5.sumhexa("api_keykeymethodauth.getToken" .. "secret"))

	local session = lastfm.sessionParams("key", "secret", "token value")
	test.equal(session.method, "auth.getSession")
	test.equal(session.token, "token value")
	test.equal(session.api_sig, md5.sumhexa("api_keykeymethodauth.getSessiontokentoken value"
	.. "secret"))

	test.equal(lastfm.authUrl("key", "token value"),
	"https://www.last.fm/api/auth/?api_key=key&token=token%20value")
end)

test.it("builds a now-playing call with the track's metadata", function()
	local params = lastfm.nowPlayingParams("key", "secret", "session", track({
		title = "Title",
		album = "Album",
		albumArtist = "Album Artist",
		number = 4,
		duration = 212.6,
	}))

	test.equal(params.method, "track.updateNowPlaying")
	test.equal(params.sk, "session")
	test.equal(params.artist, "Artist")
	test.equal(params.track, "Title")
	test.equal(params.album, "Album")
	test.equal(params.albumArtist, "Album Artist")
	test.equal(params.trackNumber, 4)
	test.equal(params.duration, 213)
end)

test.it("builds a batched scrobble with Last.fm's array notation", function()
	---@type beat.Scrobble[]
	local scrobbles = {
		{
			trackId = 1,
			artist = "Artist One",
			title = "Track One",
			album = "Album One",
			albumArtist = "Album Artist One",
			number = 1,
			duration = 100,
			startedAt = 1700000000.9,
		},
		{
			trackId = 2,
			artist = "Artist Two",
			title = "Track Two",
			album = "",
			albumArtist = "",
			duration = 200,
			startedAt = 1700000300,
		},
	}
	local params = lastfm.scrobbleParams("key", "secret", "session", scrobbles)

	test.equal(params.method, "track.scrobble")
	test.equal(params.sk, "session")
	test.equal(params["artist[0]"], "Artist One")
	test.equal(params["track[0]"], "Track One")
	test.equal(params["timestamp[0]"], 1700000000)
	test.equal(params["albumArtist[0]"], "Album Artist One")
	test.equal(params["trackNumber[0]"], 1)
	test.equal(params["artist[1]"], "Artist Two")
	test.equal(params["track[1]"], "Track Two")
	test.equal(params["timestamp[1]"], 1700000300)
	test.equal(params["album[1]"], nil, "an empty album is left out")
end)

test.it("reads Last.fm errors and successful responses", function()
	local value, err, code = lastfm.response('{"token":"abc"}')
	test.equal(value.token, "abc")
	test.equal(err, nil)
	test.equal(code, nil)

	local failed, message, errorCode = lastfm.response(
	'{"error":14,"message":"This token has not been authorized"}')
	test.equal(failed, nil)
	test.equal(message, "This token has not been authorized")
	test.equal(errorCode, 14)

	local broken, brokenMessage = lastfm.response("not json")
	test.equal(broken, nil)
	test.equal(brokenMessage, "Last.fm returned a response beat could not read")
end)
