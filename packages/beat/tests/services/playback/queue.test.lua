local test = require("lde-test")
local Queue = require("beat.app.services.playback.queue")

---@param at number
local function track(at)
	---@type beat.Track
	local fixture = {
		id = at,
		path = "/music/" .. at .. ".flac",
		title = "Track " .. at,
		artist = "Artist",
		album = "Album",
		albumId = 1,
		artistId = 1,
		albumArtist = "Artist",
		disc = 1,
		number = at,
		year = 2020,
		genre = "Genre",
		duration = 100,
		format = "flac",
		sampleRate = 44100,
		channels = 2,
		hasPicture = false,
		coverPath = nil,
		coverCache = nil,
		modified = 0,
		hash = "hash" .. at
	}
	return fixture
end

---@param count number
---@return beat.Track[]
local function tracks(count)
	local list = {}
	for at = 1, count do list[at] = track(at) end
	return list
end

test.it("walks a queue and stops at its end", function()
	local queue = Queue.new(tracks(3), 1)

	test.equal(assert(queue:current()).id, 1)
	test.equal(assert(queue:next()).id, 2)
	test.equal(assert(queue:next()).id, 3)
	test.falsy(queue:next(), "nothing follows the last track")
	test.equal(assert(queue:previous()).id, 2)
	test.equal(assert(queue:previous()).id, 1)
	test.falsy(queue:previous())
end)

test.it("repeats one track, or the whole queue", function()
	local queue = Queue.new(tracks(2), 1, { repeatMode = "one" })
	test.equal(queue:onEnded(), "again")
	test.equal(assert(queue:current()).id, 1)

	queue.repeatMode = "all"
	test.equal(queue:onEnded(), "next")
	test.equal(assert(queue:current()).id, 2)
	test.equal(queue:onEnded(), "again")
	test.equal(assert(queue:current()).id, 1)
end)

test.it("shuffles every track once, keeping the current one first", function()
	local queue = Queue.new(tracks(10), 4, { shuffle = true })
	local seen = {}

	test.equal(assert(queue:current()).id, 4, "the current track does not jump")
	for _, index in ipairs(queue.order) do
		test.falsy(seen[index], "an index appears once")
		seen[index] = true
	end
	test.equal(#queue.order, 10)
end)

test.it("starts a shuffle with no chosen track on a random one", function()
	math.randomseed(7)
	local firsts = {}
	for _ = 1, 40 do
		local queue = Queue.new(tracks(10), nil, { shuffle = true })
		firsts[assert(queue:current()).id] = true
		test.equal(#queue.order, 10)
	end
	local distinct = 0
	for _ in pairs(firsts) do distinct += 1 end
	test.truthy(distinct > 1, "the Shuffle button does not always open on the first track")
end)

test.it("a manual next moves even when repeat-one is on", function()
	local queue = Queue.new(tracks(2), 1, { repeatMode = "one" })
	test.equal(assert(queue:next()).id, 2)
	test.equal(queue:onEnded(), "again")
end)

test.it("jumps to a track already in the queue", function()
	local queue = Queue.new(tracks(4), 1)

	test.equal(assert(queue:jump(3)).id, 3)
	test.equal(assert(queue:current()).id, 3)
	test.equal(queue:upcoming(1)[1].id, 4)
	test.falsy(queue:jump(99), "a track outside the queue is not a jump")
	test.equal(assert(queue:current()).id, 3)
end)

test.it("reads the upcoming tracks by place without building the list", function()
	local queue = Queue.new(tracks(4), 2)
	test.equal(queue:upcomingCount(), 2)
	test.equal(assert(queue:upcomingAt(1)).id, 3)
	test.equal(assert(queue:upcomingAt(2)).id, 4)
	test.falsy(queue:upcomingAt(3), "past the last upcoming track")
	test.falsy(queue:upcomingAt(0), "there is no row before the next one")

	local last = Queue.new(tracks(3), 3)
	test.equal(last:upcomingCount(), 0)
	assert(last:removeAt(last.position))
	test.equal(last:upcomingCount(), 0, "a play head past the end has nothing after it")
	test.falsy(last:upcomingAt(1))
end)

test.it("restores the album order when shuffle is switched off", function()
	local queue = Queue.new(tracks(6), 3)
	test.equal(assert(queue:current()).id, 3)
	test.truthy(queue:toggleShuffle())
	test.equal(assert(queue:current()).id, 3, "the current track stays at the front")
	test.falsy(queue:toggleShuffle())
	test.equal(assert(queue:current()).id, 3, "and keeps playing")
	test.equal(assert(queue:next()).id, 4, "the next track is the one after it in the album")
end)

test.it("adds tracks after the current one or at the end", function()
	local first = track(1)
	local second = track(2)
	local extra = track(3)
	local queue = Queue.new({ first, second }, 1, {})

	queue:add({ extra }, true)
	test.equal(queue.order[1], 1)
	test.equal(queue.order[2], 3, "the added track follows the current one")
	test.equal(queue.order[3], 2)

	queue:add({ second }, false)
	test.equal(queue.order[#queue.order], 4, "an appended track is last")
end)

--- Tracks as a library has them, findable by path the way a restored session looks them up.
---@param count number
---@return beat.Track[]
---@return fun(path: string): beat.Track?
local function library(count)
	local list, byPath = tracks(count), {}
	for at = 1, #list do byPath[list[at].path] = list[at] end
	return list, function(path) return byPath[path] end
end

test.it("comes back from a saved session in the order it was in", function()
	local list, find = library(6)
	local queue = Queue.new(list, 1, { shuffle = true, repeatMode = "all", source = "playlist:4" })
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
	test.equal(assert(restored:current()).id, 3, "the next track that is still there is current")

	test.falsy(Queue.unpack(packed, function() return nil end), "with every track gone there is no queue")
end)

--- A track of one album and one artist, so a grouping test can say which is which.
---@param id number
---@param albumId number
---@param artistId number
---@param number number
---@param disc number?
---@return beat.Track
local function grouped(id, albumId, artistId, number, disc)
	local item = track(id)
	item.albumId = albumId
	item.artistId = artistId
	item.artist = "Artist " .. artistId
	item.album = "Album " .. albumId
	item.number = number
	item.disc = disc or 1
	return item
end

--- The album ids down a queue's play order, one per track.
---@param queue beat.Queue
---@return number[]
local function albumsInOrder(queue)
	local list = {}
	for at = 1, #queue.order do list[at] = queue.tracks[queue.order[at]].albumId end
	return list
end

---@param queue beat.Queue
---@return number[]
local function artistsInOrder(queue)
	local list = {}
	for at = 1, #queue.order do list[at] = queue.tracks[queue.order[at]].artistId end
	return list
end

---@param list number[]
---@return number
local function blocks(list)
	local count = 0
	local last = nil
	for _, value in ipairs(list) do
		if value ~= last then
			count += 1
			last = value
		end
	end
	return count
end

test.it("groups a queue by album and keeps each album in disc and track order", function()
	local list = {}
	for at = 1, 3 do
		list[#list + 1] = grouped(at, 10, 100, at)
		list[#list + 1] = grouped(at + 3, 20, 100, at)
		list[#list + 1] = grouped(at + 6, 30, 200, at)
	end

	-- Start on the second album's second track: its album leads the queue, with it first.
	local queue = Queue.new(list, 5, { shuffleMode = "albums" })
	test.equal(assert(queue:current()).id, 5)
	test.equal(queue.shuffleMode, "albums")
	test.truthy(queue.shuffle)

	local seen = albumsInOrder(queue)
	test.equal(#seen, 9)
	test.equal(seen[1], 20, "the current track's album leads")
	test.equal(seen[2], 20)
	test.equal(seen[3], 20)
	test.equal(blocks(seen), 3, "each album is one contiguous block")
	test.equal(queue.tracks[queue.order[1]].id, 5, "the current track leads")

	-- Each album block runs in its album's own order, the current track first only in its block.
	local first = 4
	for block = 2, 3 do
		local numbers = {}
		for at = first, first + 2 do
			numbers[#numbers + 1] = queue.tracks[queue.order[at]].number
		end
		test.equal(numbers[2], numbers[1] + 1)
		test.equal(numbers[3], numbers[2] + 1)
		first += 3
	end
end)

test.it("groups a queue by artist, albums in their order and tracks in theirs", function()
	local list = {
		grouped(1, 10, 100, 1), grouped(2, 30, 200, 1),
		grouped(3, 20, 100, 1), grouped(4, 40, 200, 1),
		grouped(5, 10, 100, 2), grouped(6, 30, 200, 2),
		grouped(7, 20, 100, 2), grouped(8, 40, 200, 2),
	}

	local queue = Queue.new(list, 7, { shuffleMode = "artists" })
	test.equal(assert(queue:current()).id, 7)

	local seen = artistsInOrder(queue)
	test.equal(blocks(seen), 2, "each artist is one contiguous block")
	test.equal(seen[1], 100, "the current track's artist leads")
	test.equal(queue.tracks[queue.order[1]].id, 7, "the current track leads")

	-- The current track leads its artist, and the artist's albums stay in the order the library
	-- named them: the current track's album block starts with it, then the other album follows.
	local albums = albumsInOrder(queue)
	test.equal(albums[1], 20, "the current track's album leads its artist")
	test.equal(albums[2], 20)
	test.equal(albums[3], 10)
	test.equal(albums[4], 10)
	test.equal(queue.tracks[queue.order[1]].number, 2, "the current track stays first in its artist")
	test.equal(queue.tracks[queue.order[2]].number, 1, "the rest of its album follows in order")
	test.equal(queue.tracks[queue.order[3]].number, 1)
	test.equal(queue.tracks[queue.order[4]].number, 2)
end)

test.it("puts the natural order back when a grouped shuffle is switched off", function()
	local list = tracks(6)
	local queue = Queue.new(list, 4, { shuffleMode = "albums" })
	test.equal(queue.shuffleMode, "albums")

	test.equal(queue:setShuffleMode("off"), "off")
	test.falsy(queue.shuffle)
	test.equal(assert(queue:current()).id, 4, "the current track keeps playing")
	for at = 1, 6 do
		test.equal(queue.tracks[queue.order[at]].id, at, "the queue is back in the album's order")
	end
end)

test.it("toggles between the plain shuffle and off, a grouped mode counting as on", function()
	local queue = Queue.new(tracks(6), 1, { shuffleMode = "artists" })
	test.falsy(queue:toggleShuffle(), "a press on an active grouped shuffle switches it off")
	test.equal(queue.shuffleMode, "off")
	test.truthy(queue:toggleShuffle())
	test.equal(queue.shuffleMode, "tracks", "the next press is the plain shuffle")
end)

test.it("keeps a grouped shuffle and its order in a saved session, and reads an old one as tracks", function()
	local list, find = library(6)
	local queue = Queue.new(list, 2, { shuffleMode = "albums", repeatMode = "all" })
	local restored = assert(Queue.unpack(queue:pack(), find))
	test.equal(restored.shuffleMode, "albums")
	test.equal(restored.shuffle, true)
	for at = 1, 6 do
		test.equal(restored.tracks[restored.order[at]], queue.tracks[queue.order[at]], "the grouped order is kept")
	end

	local old = queue:pack()
	old.shuffleMode = nil
	old.shuffle = true
	local legacy = assert(Queue.unpack(old, find))
	test.equal(legacy.shuffleMode, "tracks", "a session from before the modes was the plain shuffle")
end)

test.it("removes an upcoming track without touching what plays", function()
	local queue = Queue.new(tracks(5), 2)
	test.equal(assert(queue:current()).id, 2)

	local removed = assert(queue:removeUpcoming(2))
	test.truthy(removed)
	test.falsy(removed.wasCurrent)
	test.equal(removed.track.id, 4, "the overlay's second row is the second upcoming track")
	test.equal(assert(queue:current()).id, 2, "the current track is untouched")
	test.equal(#queue.order, 4)
	test.equal(#queue.tracks, 4)
	test.equal(queue:upcoming(1)[1].id, 3)
	test.equal(#queue.naturalOrder, 4, "the removed track does not come back with a shuffle-off")
	for _, index in ipairs(queue.naturalOrder) do
		test.truthy(queue.tracks[index] ~= nil, "every natural position still names a track")
	end
end)

test.it("removing the current track moves on to the next one", function()
	local queue = Queue.new(tracks(4), 2)
	local removed = assert(queue:removeAt(queue.position))
	test.truthy(removed.wasCurrent)
	test.equal(removed.track.id, 2)
	test.equal(assert(queue:current()).id, 3)
	test.equal(queue:upcoming(1)[1].id, 4)

	local last = Queue.new(tracks(3), 3)
	assert(last:removeAt(last.position))
	test.falsy(last:current(), "nothing follows the last track")
	test.equal(#last.order, 2)
end)

test.it("moves a row of the upcoming queue and keeps the current track", function()
	local queue = Queue.new(tracks(4), 1)
	test.truthy(queue:moveUpcoming(2, 1))
	test.equal(queue:upcoming(3)[1].id, 3)
	test.equal(queue:upcoming(3)[2].id, 2)
	test.equal(assert(queue:current()).id, 1)
	test.equal(queue.tracks[queue.naturalOrder[2]].id, 3, "the move is kept when shuffle is off")
	test.falsy(queue:moveUpcoming(1, 9), "a row outside the list is not a move")
end)

test.it("moves rows of a shuffled queue without changing the shuffle", function()
	local queue = Queue.new(tracks(6), 1, { shuffleMode = "tracks" })
	local before = {}
	for at = 2, 6 do before[at] = queue.order[at] end
	test.truthy(queue:moveUpcoming(1, 3))

	test.equal(assert(queue:current()).id, 1, "the current track stays where it is")
	test.equal(queue.order[4], before[2], "the first upcoming row moved to the third")
	test.equal(queue.order[2], before[3])
	test.equal(queue.shuffleMode, "tracks")

	-- A move across the current track keeps the current index current.
	queue.position = 3
	local current = queue.order[3]
	test.truthy(queue:moveAt(1, 5))
	test.equal(queue.order[queue.position], current)
end)

test.it("orders one album's tracks by disc and then by track number", function()
	local list = {
		grouped(1, 10, 100, 1, 2),
		grouped(2, 10, 100, 2, 1),
		grouped(3, 10, 100, 1, 1),
	}
	local queue = Queue.new(list, nil, { shuffleMode = "albums" })
	test.equal(#queue.order, 3)
	test.equal(queue.tracks[queue.order[1]].id, 3, "disc one, track one")
	test.equal(queue.tracks[queue.order[2]].id, 2, "disc one, track two")
	test.equal(queue.tracks[queue.order[3]].id, 1, "disc two follows")
end)

test.it("skips the rest of an album or artist in the order it is playing", function()
	local list = {
		grouped(1, 10, 100, 1), grouped(2, 10, 100, 2), grouped(3, 10, 100, 3),
		grouped(4, 20, 200, 1), grouped(5, 20, 200, 2),
		grouped(6, 30, 100, 1)
	}

	local byAlbum = Queue.new(list, 2)
	test.equal(assert(byAlbum:skipGroup("album")).id, 4, "the next album's first track")
	test.equal(byAlbum.position, 4)
	test.equal(assert(byAlbum:skipGroup("album")).id, 6, "and then the one after it")
	test.falsy(byAlbum:skipGroup("album"), "the last album runs to the end of the queue")

	local byArtist = Queue.new(list, 2)
	test.equal(assert(byArtist:skipGroup("artist")).id, 4, "the next artist's first track")
	test.equal(assert(byArtist:skipGroup("artist")).id, 6, "the artist after that")
	test.falsy(byArtist:skipGroup("artist"), "with no other artist left")
end)

test.it("skips groups along a shuffled order, not the natural one", function()
	local list = {
		grouped(1, 10, 100, 1), grouped(2, 10, 100, 2), grouped(3, 10, 100, 3),
		grouped(4, 20, 200, 1), grouped(5, 20, 200, 2),
		grouped(6, 30, 100, 1)
	}
	local queue = Queue.new(list, 1, { shuffleMode = "tracks" })
	-- A shuffle that put album 20 first, then album 10, then album 30.
	queue.order = { 4, 5, 1, 2, 3, 6 }
	queue.position = 3

	test.equal(assert(queue:skipGroup("album")).id, 6, "album 30 follows album 10 in this shuffle")
	test.equal(queue.position, 6)

	queue.position = 1
	test.equal(assert(queue:skipGroup("artist")).id, 1, "the next artist in this order is the one at 1")
end)

test.it("stops at the end of a group with nothing after it", function()
	local list = { grouped(1, 10, 100, 1), grouped(2, 10, 100, 2) }
	local queue = Queue.new(list, 1)

	test.falsy(queue:skipGroup("album"))
	test.falsy(queue:skipGroup("artist"))
	test.equal(queue.position, 1, "the play head stays; the caller stops as it does at the end")
	test.equal(assert(queue:current()).id, 1, "and the current track is still current")
end)
