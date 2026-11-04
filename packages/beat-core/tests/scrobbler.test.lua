local test = require("lde-test")
local core = require("beat-core")

local function track(id, duration)
	return {
	id = id,
	title = "Title " .. id,
	artist = "Artist",
	album = "Album",
	duration = duration,
	}
end

test.it("queues a scrobble once the track has been heard halfway", function()
	local scrobbler = core.Scrobbler.new()
	local song = track(1, 100)

	scrobbler:update(song, 0, true, 10)
	for position = 1, 50 do scrobbler:update(song, position, true, 10 + position) end

	local queued = scrobbler:take()
	test.equal(#queued, 1, "one scrobble was queued")
	test.equal(queued[1].title, "Title 1")
	test.equal(queued[1].startedAt, 10)
end)

test.it("does not queue a track under thirty seconds", function()
	local scrobbler = core.Scrobbler.new()
	local song = track(2, 20)

	for position = 1, 20 do scrobbler:update(song, position, true, position) end

	test.equal(#scrobbler:take(), 0)
end)

test.it("does not count a seek as listening", function()
	local scrobbler = core.Scrobbler.new()
	local song = track(3, 100)

	scrobbler:update(song, 0, true, 0)
	scrobbler:update(song, 60, true, 1)

	test.equal(#scrobbler:take(), 0, "jumping to sixty seconds is not half of the track")
end)

test.it("queues a track that reached the threshold after a normal step", function()
	local scrobbler = core.Scrobbler.new()
	local song = track(4, 100)

	for position = 1, 50 do scrobbler:update(song, position, true, position) end
	test.equal(#scrobbler:take(), 1)
end)
