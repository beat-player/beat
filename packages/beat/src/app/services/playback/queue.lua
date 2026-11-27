-- The playback order: what is playing, what comes next, and how the two ends of the queue behave.
-- It is state, not a player; `beat.app.services.playback.player` is what hands this order to treble.

--- What the shuffle button does when it is pressed without a menu. `tracks` is the plain shuffle
--- the button has always had; `albums` and `artists` group the order rather than randomising every
--- track, and `off` is the natural order the queue was made with.
---@alias beat.ShuffleMode "off"|"tracks"|"albums"|"artists"

---@class beat.Queue
---@field tracks beat.Track[]
---@field order number[]
---@field naturalOrder number[]
---@field position number
---@field repeatMode "off"|"all"|"one"
---@field shuffle boolean # Whether any shuffle is on; `shuffleMode` says which
---@field shuffleMode beat.ShuffleMode
---@field source string
local Queue = {}
Queue.__index = Queue

---@param mode string?
---@return beat.ShuffleMode
local function validMode(mode)
	if mode == "tracks" or mode == "albums" or mode == "artists" then return mode end
	return "off"
end

---@param list any[]
---@param rand fun(n: number): number
local function shuffleInPlace(list, rand)
	for at = #list, 2, -1 do
		local other = rand(at)
		list[at], list[other] = list[other], list[at]
	end
end

---@param indexes number[]
---@return table<number, number>
local function ranksOf(indexes)
	local rank = {}
	for at, index in ipairs(indexes) do rank[index] = at end
	return rank
end

--- The order inside one album: its disc, then its track number, then its title, with the natural
--- order settling anything still equal. The album's own `tracks` follow this order already, so a
--- queue built from an album keeps the order it was shown in.
---@param tracks beat.Track[]
---@param rank table<number, number>
---@param a number
---@param b number
---@return boolean
local function albumLess(tracks, rank, a, b)
	local left, right = tracks[a], tracks[b]
	local leftDisc, rightDisc = left.disc or 1, right.disc or 1
	if leftDisc ~= rightDisc then return leftDisc < rightDisc end
	local leftNumber, rightNumber = left.number or math.huge, right.number or math.huge
	if leftNumber ~= rightNumber then return leftNumber < rightNumber end
	local leftTitle, rightTitle = left.title or "", right.title or ""
	if leftTitle ~= rightTitle then return leftTitle < rightTitle end
	return (rank[a] or 0) < (rank[b] or 0)
end

---@param list any[]
---@param value any
local function moveFirst(list, value)
	for at, item in ipairs(list) do
		if item == value then
			table.remove(list, at)
			table.insert(list, 1, value)
			return
		end
	end
end

--- Indexes by a grouping key, in the order the natural order first names each key. The keys are
--- kept beside the groups so a shuffle can move whole groups without hashing them again.
---@param tracks beat.Track[]
---@param natural number[]
---@param keyOf fun(track: beat.Track): any
---@return any[] keys
---@return table<any, number[]> groups
local function groupsOf(tracks, natural, keyOf)
	local keys, groups = {}, {}
	for _, index in ipairs(natural) do
		local track = tracks[index]
		if track ~= nil then
			local key = keyOf(track) or ""
			local group = groups[key]
			if group == nil then
				keys[#keys + 1] = key
				group = {}
				groups[key] = group
			end
			group[#group + 1] = index
		end
	end
	return keys, groups
end

---@param track beat.Track
---@return any
local function albumKey(track)
	return track.albumId or track.album or ""
end

--- An artist is the library's artist, which groups albums by `albumArtist`, so a track's
--- `artistId` is the artist whose page it appears on. The name is the fallback for a record that
--- has no id yet.
---@param track beat.Track
---@return any
local function artistKey(track)
	return track.artistId or track.artist or ""
end

--- Moves one album's block within a list to its front, keeping the rest in order, and puts
--- `current` at the head of that block. An artist's tracks are grouped by album, so bringing the
--- current track forward means bringing its album with it.
---@param list number[]
---@param tracks beat.Track[]
---@param current number
local function moveAlbumFirst(list, tracks, current)
	local key = albumKey(tracks[current])
	local block, rest = {}, {}
	for _, index in ipairs(list) do
		if albumKey(tracks[index]) == key then
			block[#block + 1] = index
		else
			rest[#rest + 1] = index
		end
	end
	moveFirst(block, current)
	for at = #block, 1, -1 do table.insert(rest, 1, block[at]) end
	for at = #list, 1, -1 do list[at] = nil end
	for _, index in ipairs(rest) do list[#list + 1] = index end
end

--- The play order one shuffle mode makes of a track list, as a permutation of the track indexes.
--- Pure over its arguments except for `rand`, so a test can pin the random order:
---
--- * `off` is the natural order.
--- * `tracks` keeps `current` first, then every other track once, at random.
--- * `albums` shuffles whole albums and keeps each album's own disc/track order inside it.
--- * `artists` shuffles whole artists; inside an artist its albums keep their natural order and
---   each album its disc/track order.
---
--- A grouped mode with a `current` track leads with that track, then the rest of its album, and
--- for `artists` the rest of that artist. Its group stays contiguous and the current track keeps
--- playing from the head of the queue.
---@param tracks beat.Track[]
---@param mode string?
---@param natural number[] # The order the queue was made in
---@param current number? # The track index to keep first
---@param rand fun(n: number): number?
---@return number[]
function Queue.arrange(tracks, mode, natural, current, rand)
	mode = validMode(mode)
	rand = rand or math.random

	local order = {}
	if mode == "off" then
		for at, index in ipairs(natural) do order[at] = index end
		return order
	end

	local rank = ranksOf(natural)
	if tracks[current or 0] == nil then current = nil end

	if mode == "tracks" then
		local rest = {}
		for _, index in ipairs(natural) do
			if index ~= current then rest[#rest + 1] = index end
		end
		shuffleInPlace(rest, rand)
		if current ~= nil then order[1] = current end
		for _, index in ipairs(rest) do order[#order + 1] = index end
		return order
	end

	local keyOf = mode == "albums" and albumKey or artistKey
	local keys, groups = groupsOf(tracks, natural, keyOf)
	for _, key in ipairs(keys) do
		table.sort(groups[key], |a, b| -> albumLess(tracks, rank, a, b))
	end

	if mode == "artists" then
		-- Albums inside an artist stay in the order the natural order first names them; only the
		-- artists themselves are shuffled.
		for _, key in ipairs(keys) do
			local list = groups[key]
			local albumRanks, albumKeys = {}, {}
			for _, index in ipairs(list) do
				local album = albumKey(tracks[index])
				if albumRanks[album] == nil then
					albumKeys[#albumKeys + 1] = album
					albumRanks[album] = #albumKeys
				end
			end
			table.sort(list, function(a, b)
				local leftAlbum, rightAlbum = albumKey(tracks[a]), albumKey(tracks[b])
				local leftRank, rightRank = albumRanks[leftAlbum], albumRanks[rightAlbum]
				if leftRank ~= rightRank then return leftRank < rightRank end
				return albumLess(tracks, rank, a, b)
			end)
		end
	end

	shuffleInPlace(keys, rand)
	if current ~= nil then
		local key = keyOf(tracks[current])
		local group = groups[key]
		if group ~= nil then
			moveFirst(keys, key)
			if mode == "artists" then
				moveAlbumFirst(group, tracks, current)
			else
				moveFirst(group, current)
			end
		end
	end
	for _, key in ipairs(keys) do
		for _, index in ipairs(groups[key]) do order[#order + 1] = index end
	end
	return order
end

---@param tracks beat.Track[]
---@param index number? # The track to start on; without one a shuffled queue starts on a random track
---@param opts { repeatMode: string?, shuffle: boolean?, shuffleMode: beat.ShuffleMode?, source: string? }?
---@return beat.Queue
function Queue.new(tracks, index, opts)
	opts = opts or {}
	local own = {}
	for at = 1, #tracks do own[at] = tracks[at] end
	local order = {}
	local naturalOrder = {}
	for at = 1, #own do
		order[at] = at
		naturalOrder[at] = at
	end

	local mode = opts.shuffleMode
	if mode == nil then mode = opts.shuffle == true and "tracks" or "off" end
	mode = validMode(mode)

	local queue = setmetatable({
		-- The queue's own array rather than the caller's: what is queued is mostly an album's or
		-- an artist's tracks, which are the library's, and a queue that appended to the array it
		-- was handed would be adding tracks to the album itself.
		tracks = own,
		order = order,
		naturalOrder = naturalOrder,
		position = math.max(1, math.min(index or 1, #own)),
		repeatMode = opts.repeatMode or "off",
		shuffle = mode ~= "off",
		shuffleMode = mode,
		source = opts.source or "library"
	}, Queue)

	-- A track picked to start on stays first; a shuffle with nothing picked -- the Shuffle button --
	-- draws the first track at random too.
	if queue.shuffleMode ~= "off" then
		queue.order = Queue.arrange(own, mode, naturalOrder, index ~= nil and order[queue.position] or nil)
		queue.position = 1
	end

	return queue
end

---@return beat.Track?
function Queue:current()
	local index = self.order[self.position]
	if index == nil then return nil end
	return self.tracks[index]
end

---@return beat.Track[]
function Queue:upcoming(limit)
	---@type beat.Track[]
	local list = {}
	for at = self.position + 1, #self.order do
		local track = self.tracks[self.order[at]] --[[@as beat.Track?]]
		if track ~= nil then
			list[#list + 1] = track
			if limit ~= nil and #list >= limit then break end
		end
	end
	return list
end

--- How many tracks come after the one playing: the rows the queue panel draws. It reads the order
--- in place, so a view asks for the number without building the list it is the length of.
---@return number
function Queue:upcomingCount()
	local count = #self.order - self.position
	if count < 0 then return 0 end
	return count
end

--- The upcoming track at one place, 1 being the next one. The order names a track at every place
--- it holds -- building the queue and removing a track both keep it that way -- so a visible row
--- is a read rather than a walk from the play head.
---@param index number
---@return beat.Track?
function Queue:upcomingAt(index)
	if index == nil or index < 1 then return nil end
	local trackIndex = self.order[self.position + index]
	if trackIndex == nil then return nil end
	return self.tracks[trackIndex]
end

--- The order the current mode makes, with the current track first, then every other one once.
--- A restart at the end of repeat-all shuffles everything instead, so the same track is not played
--- twice.
---@param keepCurrent boolean?
function Queue:shuffleOrder(keepCurrent)
	if self.shuffleMode == "off" then return end
	keepCurrent = keepCurrent ~= false
	local current = keepCurrent and self.order[self.position] or nil
	self.order = Queue.arrange(self.tracks, self.shuffleMode, self.naturalOrder, current)
	self.position = 1
end

--- Switches which shuffle is on. The track playing stays playing: in a grouped mode it leads the
--- order and its group follows it, and `off` puts the natural order back around it.
---@param mode beat.ShuffleMode
---@return beat.ShuffleMode
function Queue:setShuffleMode(mode)
	mode = validMode(mode)
	if mode == self.shuffleMode then return self.shuffleMode end

	local current = self.order[self.position]
	self.shuffleMode = mode
	self.shuffle = mode ~= "off"

	if mode == "off" then
		local order = {}
		for at, index in ipairs(self.naturalOrder) do order[at] = index end
		self.order = order
		self.position = 1
		if current ~= nil then
			for at, index in ipairs(order) do
				if index == current then
					self.position = at
					break
				end
			end
		end
		self.position = math.max(1, math.min(self.position, #order))
	else
		self.order = Queue.arrange(self.tracks, mode, self.naturalOrder, current)
		self.position = 1
	end
	return self.shuffleMode
end

--- Moves the play head to a track already in the queue, keeping the order.
---@param trackId number
---@return beat.Track?
function Queue:jump(trackId)
	for at, index in ipairs(self.order) do
		local track = self.tracks[index]
		if track?.id == trackId then
			self.position = at
			return track
		end
	end
	return nil
end

---@param index number
function Queue:setPosition(index)
	self.position = math.max(1, math.min(index, #self.order))
end

--- What a manual next asks for. Repeat-one does not loop here: a manual skip means the next
--- track, even when the automatic end of a track would repeat this one.
---@return beat.Track?
function Queue:next()
	if self.position < #self.order then
		self.position += 1
		return self:current()
	end

	if self.repeatMode == "all" and #self.order > 0 then
		if self.shuffleMode ~= "off" then
			self:shuffleOrder(false)
		else
			self.position = 1
		end
		return self:current()
	end

	return nil
end

---@return beat.Track?
function Queue:previous()
	if self.position > 1 then
		self.position -= 1
		return self:current()
	end

	if self.repeatMode == "all" and #self.order > 0 then
		self.position = #self.order
		return self:current()
	end

	return nil
end

--- What a skip button's menu asks for: the first upcoming track whose album or artist differs
--- from the one playing, in the order the queue is in now. Nothing after this group means there
--- is nothing to skip to, and the caller stops as it would at the end of the queue.
---@param by "album"|"artist"
---@return beat.Track? # The track the play head moved to; nothing when the group runs to the end
function Queue:skipGroup(by)
	local current = self:current()
	if current == nil then return nil end

	local keyOf
	if by == "album" then
		keyOf = albumKey
	elseif by == "artist" then
		keyOf = artistKey
	else
		return nil
	end

	local key = keyOf(current)
	for at = self.position + 1, #self.order do
		local track = self.tracks[self.order[at]]
		if track ~= nil and keyOf(track) ~= key then
			self.position = at
			return track
		end
	end

	return nil
end

--- What the end of a track asks for. Unlike a manual skip, repeat-one stays here.
---@return "again"|"next"|"stop"
function Queue:onEnded()
	if self.repeatMode == "one" then return "again" end
	if self.position < #self.order then
		self.position += 1
		return "next"
	end

	if self.repeatMode == "all" and #self.order > 0 then
		if self.shuffleMode ~= "off" then
			self:shuffleOrder(false)
		else
			self.position = 1
		end
		return "again"
	end

	return "stop"
end

---@return "off"|"all"|"one"
function Queue:cycleRepeat()
	if self.repeatMode == "off" then
		self.repeatMode = "all"
	elseif self.repeatMode == "all" then
		self.repeatMode = "one"
	else
		self.repeatMode = "off"
	end
	return self.repeatMode
end

--- The shuffle button without its menu: any shuffle goes off, and off goes to the plain track
--- shuffle. A grouped mode is still "on", so the button's first press turns it off rather than
--- switching to a different kind of shuffle.
---@return boolean # Whether a shuffle is on now
function Queue:toggleShuffle()
	self:setShuffleMode(self.shuffleMode == "off" and "tracks" or "off")
	return self.shuffle
end

--- Removes one position from the play order. `index` is 1-based in `order`, so the current track
--- is at `position` and the overlay's first row is at `position + 1`. A queue that loses the track
--- it is on moves on to the next one; removing any other track leaves playback where it is.
---@param index number # 1-based in `order`
---@return { track: beat.Track?, wasCurrent: boolean }?
function Queue:removeAt(index)
	if index < 1 or index > #self.order then return nil end

	local trackIndex = self.order[index]
	local track = self.tracks[trackIndex]
	local wasCurrent = index == self.position

	table.remove(self.order, index)
	table.remove(self.tracks, trackIndex)
	for at = 1, #self.order do
		local value = self.order[at]
		if value > trackIndex then self.order[at] = value - 1 end
	end
	for at = #self.naturalOrder, 1, -1 do
		local value = self.naturalOrder[at]
		if value == trackIndex then
			table.remove(self.naturalOrder, at)
		elseif value > trackIndex then
			self.naturalOrder[at] = value - 1
		end
	end

	local count = #self.order
	if wasCurrent then
		-- The removal shifted the next track into this position. A queue whose current track was
		-- the last one has nothing left to move on to: the play head sits past the end, where
		-- `current` is nil, rather than stepping back to a track already played.
		if index > count then
			self.position = count + 1
		end
	elseif index < self.position then
		self.position -= 1
	end
	return { track = track, wasCurrent = wasCurrent }
end

--- Removes the over-the-overlay row `index`: 1 is the next track, not the one playing.
---@param index number
---@return { track: beat.Track?, wasCurrent: boolean }?
function Queue:removeUpcoming(index)
	if index == nil or index < 1 then return nil end
	return self:removeAt(self.position + index)
end

--- Moves one position of the play order to another. Both are 1-based positions in `order`, so a
--- move that crosses the current track keeps the current track playing where it is.
---@param from number
---@param to number
---@return boolean
function Queue:moveAt(from, to)
	local count = #self.order
	if from == nil or to == nil or from < 1 or from > count or to < 1 or to > count or from == to then
		return false
	end

	-- A new array rather than a move in place: the session writer compares the order's identity
	-- to know it changed, and a reorder keeps the same length.
	local order = {}
	for at = 1, count do order[at] = self.order[at] end
	local value = table.remove(order, from)
	table.insert(order, to, value)
	self.order = order
	if from < self.position and to >= self.position then
		self.position -= 1
	elseif from > self.position and to <= self.position then
		self.position += 1
	end

	-- Nothing is shuffled, so the natural order is the play order: a later shuffle-off must keep
	-- the move rather than undo it.
	if self.shuffleMode == "off" then
		local natural = {}
		for at, index in ipairs(self.order) do natural[at] = index end
		self.naturalOrder = natural
	end
	return true
end

--- Moves the over-the-overlay row `from` to row `to`: positions among the upcoming tracks, the
--- current track not counted. The current track is never moved.
---@param from number
---@param to number
---@return boolean
function Queue:moveUpcoming(from, to)
	local count = #self.order - self.position
	if from == nil or to == nil or from < 1 or to < 1 or from > count or to > count then return false end
	return self:moveAt(self.position + from, self.position + to)
end

---@return number
function Queue:sourceIndex()
	return self.order[self.position] or 1
end

--- Adds tracks after the play head or at the end, without disturbing what is playing.
---@param tracks beat.Track[]
---@param afterCurrent boolean?
function Queue:add(tracks, afterCurrent)
	local at = afterCurrent and (self.position + 1) or (#self.order + 1)

	for _, track in ipairs(tracks) do
		self.tracks[#self.tracks + 1] = track
		local index = #self.tracks
		table.insert(self.order, at, index)
		self.naturalOrder[#self.naturalOrder + 1] = index
		at += 1
	end
end

---@param tracks beat.Track[]
---@param index number?
function Queue:replace(tracks, index)
	-- The queue's own array, for the reason `Queue.new` keeps one: `Queue:add` appends to it.
	local own = {}
	for at = 1, #tracks do own[at] = tracks[at] end
	self.tracks = own
	local order = {}
	local naturalOrder = {}
	for at = 1, #own do
		order[at] = at
		naturalOrder[at] = at
	end
	self.order = order
	self.naturalOrder = naturalOrder
	self.position = math.max(1, math.min(index or 1, #own))
	if self.shuffleMode ~= "off" then
		local current = self.order[self.position]
		self.order = Queue.arrange(self.tracks, self.shuffleMode, self.naturalOrder, current)
		self.position = 1
	end
end

--- The queue as a session file keeps it: tracks by path, the one identity a track keeps across a
--- rescan, and the order and play head as they stand.
---@return table
function Queue:pack()
	local paths = {}
	for at, track in ipairs(self.tracks) do paths[at] = track.path end

	return {
		tracks = paths,
		order = self.order,
		naturalOrder = self.naturalOrder,
		position = self.position,
		repeatMode = self.repeatMode,
		shuffle = self.shuffle,
		shuffleMode = self.shuffleMode,
		source = self.source
	}
end

local REPEAT_MODES = { off = true, all = true, one = true }

--- A packed queue put back, in the order it was in rather than a new shuffle. A track whose path
--- the library no longer has is left out; if that was the current one, the play head moves to the
--- first track after it that is still there. Nothing left is no queue.
---@param packed table
---@param find fun(path: string): beat.Track?
---@return beat.Queue?
---@return boolean # Whether the current track is the one that was current
function Queue.unpack(packed, find)
	if type(packed) ~= "table" or type(packed.tracks) ~= "table" or type(packed.order) ~= "table" or type(
		packed.naturalOrder
	) ~= "table" or type(packed.position) ~= "number" then
		return nil, false
	end

	local tracks, moved = {}, {}
	for at, path in ipairs(packed.tracks) do
		local track = type(path) == "string" ? find(path) : nil
		if track ~= nil then
			tracks[#tracks + 1] = track
			moved[at] = #tracks
		end
	end
	if #tracks == 0 then return nil, false end

	local function remap(list)
		local out = {}
		for _, index in ipairs(list) do
			if moved[index] ~= nil then out[#out + 1] = moved[index] end
		end
		return out
	end

	local order = remap(packed.order)
	if #order == 0 then return nil, false end
	local before = 0
	for at = 1, math.min(packed.position - 1, #packed.order) do
		if moved[packed.order[at]] ~= nil then before += 1 end
	end

	-- A session written before the modes existed kept only whether shuffle was on; it comes back
	-- as the plain track shuffle it was.
	local mode = validMode(packed.shuffleMode)
	if packed.shuffleMode == nil and packed.shuffle == true then mode = "tracks" end

	local queue = setmetatable({
		tracks = tracks,
		order = order,
		naturalOrder = remap(packed.naturalOrder),
		position = math.min(before + 1, #order),
		repeatMode = REPEAT_MODES[packed.repeatMode] and packed.repeatMode or "off",
		shuffle = mode ~= "off",
		shuffleMode = mode,
		source = type(packed.source) == "string" and packed.source or "library"
	}, Queue)

	return queue, moved[packed.order[packed.position]] ~= nil
end

return Queue
