local test = require("lde-test")
local Queue = require("beat.app.services.playback.queue")

local function tracks(count)
	local list = {}
	for at = 1, count do list[at] = { id = at, title = "Track " .. at} end
	return list
end

test.it("walks a queue and stops at its end", function()
	local queue = Queue.new(tracks(3), 1)

	test.equal(queue:current().id, 1)
	test.equal(queue:next().id, 2)
	test.equal(queue:next().id, 3)
	test.falsy(queue:next(), "nothing follows the last track")
	test.equal(queue:previous().id, 2)
	test.equal(queue:previous().id, 1)
	test.falsy(queue:previous())
end)

test.it("repeats one track, or the whole queue", function()
	local queue = Queue.new(tracks(2), 1, { repeatMode = "one"})
	test.equal(queue:onEnded(), "again")
	test.equal(queue:current().id, 1)

	queue.repeatMode = "all"
	test.equal(queue:onEnded(), "next")
	test.equal(queue:current().id, 2)
	test.equal(queue:onEnded(), "again")
	test.equal(queue:current().id, 1)
end)

test.it("shuffles every track once, keeping the current one first", function()
	local queue = Queue.new(tracks(10), 4, { shuffle = true})
	local seen = {}

	test.equal(queue:current().id, 4, "the current track does not jump")
	for _, index in ipairs(queue.order) do
			test.falsy(seen[index], "an index appears once")
			seen[index] = true
		end
	test.equal(#queue.order, 10)
end)

test.it("a manual next moves even when repeat-one is on", function()
	local queue = Queue.new(tracks(2), 1, { repeatMode = "one"})
	test.equal(queue:next().id, 2)
	test.equal(queue:onEnded(), "again")
end)

test.it("jumps to a track already in the queue", function()
	local queue = Queue.new(tracks(4), 1)

	test.equal(queue:jump(3).id, 3)
	test.equal(queue:current().id, 3)
	test.equal(queue:upcoming(1)[1].id, 4)
	test.falsy(queue:jump(99), "a track outside the queue is not a jump")
	test.equal(queue:current().id, 3)
end)

test.it("restores the album order when shuffle is switched off", function()
	local queue = Queue.new(tracks(6), 3)
	test.equal(queue:current().id, 3)
	test.truthy(queue:toggleShuffle())
	test.equal(queue:current().id, 3, "the current track stays at the front")
	test.falsy(queue:toggleShuffle())
	test.equal(queue:current().id, 3, "and keeps playing")
	test.equal(queue:next().id, 4, "the next track is the one after it in the album")
end)

test.it("adds tracks after the current one or at the end", function()
	local first = { id = 1, title = "One", artist = "A", album = "B", duration = 10}
	local second = { id = 2, title = "Two", artist = "A", album = "B", duration = 10}
	local extra = { id = 3, title = "Three", artist = "A", album = "B", duration = 10}
	local queue = Queue.new({ first, second}, 1, {})

	queue:add({ extra}, true)
	test.equal(queue.order[1], 1)
	test.equal(queue.order[2], 3, "the added track follows the current one")
	test.equal(queue.order[3], 2)

	queue:add({ second}, false)
	test.equal(queue.order[#queue.order], 4, "an appended track is last")
end)

--- Tracks as a library has them, findable by path the way a restored session looks them up.
local function library(count)
	local list, byPath = {}, {}
	for at = 1, count do
		list[at] = { id = at, title = "Track " .. at, path = "/music/" .. at .. ".flac"}
		byPath[list[at].path] = list[at]
	end
	return list, function(path) return byPath[path] end
end

test.it("comes back from a saved session in the order it was in", function()
	local list, find = library(6)
	local queue = Queue.new(list, 1, { shuffle = true, repeatMode = "all", source = "playlist:4"})
	queue:next()
	queue:next()

	local restored, sameTrack = Queue.unpack(queue:pack(), find)
	assert(restored)
	test.truthy(sameTrack)
	test.equal(restored:current(), queue:current(), "the same track is current")
	for at = 1, 6 do
		test.equal(restored.tracks[restored.order[at]], queue.tracks[queue.order[at]], "the shuffle is kept, not redrawn")
	end
	test.equal(restored.shuffle, true)
	test.equal(restored.repeatMode, "all")
	test.equal(restored.source, "playlist:4")

	restored:toggleShuffle()
	for at = 1, 6 do
		test.equal(restored.tracks[restored.order[at]].id, at, "switching shuffle off finds the album order")
	end
	test.equal(restored:current(), queue:current(), "at the same track")
end)

test.it("leaves out tracks that are gone, and moves on from a current one that is", function()
	local list, find = library(4)
	local packed = Queue.new(list, 2):pack()

	local restored, sameTrack = Queue.unpack(packed, function(path)
		if path == "/music/2.flac" then return nil end
		return find(path)
	end)
	assert(restored)
	test.falsy(sameTrack, "the track that was playing is gone")
	test.equal(#restored.order, 3)
	test.equal(restored:current().id, 3, "the next track that is still there is current")

	test.falsy(Queue.unpack(packed, function() return nil end), "with every track gone there is no queue")
end)
