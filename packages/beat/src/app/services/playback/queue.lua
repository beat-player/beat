-- The playback order: what is playing, what comes next, and how the two ends of the queue behave.
-- It is state, not a player; `beat.app.services.playback.player` is what hands this order to treble.

---@class beat.Queue
---@field tracks beat.Track[]
---@field order number[]
---@field naturalOrder number[]
---@field position number
---@field repeatMode "off"|"all"|"one"
---@field shuffle boolean
---@field source string
local Queue = {}
Queue.__index = Queue

---@param tracks beat.Track[]
---@param index number?
---@param opts { repeatMode: string?, shuffle: boolean?, source: string? }?
---@return beat.Queue
function Queue.new(tracks, index, opts)
	opts = opts or {}
	local order = {}
	local naturalOrder = {}
	for at = 1, #tracks do
			order[at] = at
			naturalOrder[at] = at
		end

	local queue = setmetatable({
	tracks = tracks,
	order = order,
	naturalOrder = naturalOrder,
	position = math.max(1, math.min(index or 1, #tracks)),
	repeatMode = opts.repeatMode or "off",
	shuffle = opts.shuffle or false,
	source = opts.source or "library",
	}, Queue)

	if queue.shuffle then queue:shuffleOrder() end

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
	local list = {}
	for at = self.position + 1, #self.order do
			local track = self.tracks[self.order[at]]
			if track ~= nil then
				list[#list + 1] = track
				if limit ~= nil and #list >= limit then break end
			end
		end
	return list
end

--- The order with the current track first, then every other one once, at random. A restart at
--- the end of repeat-all shuffles everything instead, so the same track is not played twice.
---@param keepCurrent boolean?
function Queue:shuffleOrder(keepCurrent)
	keepCurrent = keepCurrent ~= false
	local current = keepCurrent and self.order[self.position] or nil
	local rest = {}
	for _, index in ipairs(self.order) do
			if index ~= current then rest[#rest + 1] = index end
		end

	for at = #rest, 2, -1 do
			local other = math.random(at)
			rest[at], rest[other] = rest[other], rest[at]
		end

	local order = {}
	if current ~= nil then order[1] = current end
	for _, index in ipairs(rest) do order[#order + 1] = index end

	self.order = order
	self.position = 1
end

--- Moves the play head to a track already in the queue, keeping the order.
---@param trackId number
---@return beat.Track?
function Queue:jump(trackId)
	for at, index in ipairs(self.order) do
			local track = self.tracks[index]
			if track ~= nil and track.id == trackId then
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
		self.position = self.position + 1
		return self:current()
	end

	if self.repeatMode == "all" and #self.order > 0 then
		if self.shuffle then
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
		self.position = self.position - 1
		return self:current()
	end

	if self.repeatMode == "all" and #self.order > 0 then
		self.position = #self.order
		return self:current()
	end

	return nil
end

--- What the end of a track asks for. Unlike a manual skip, repeat-one stays here.
---@return "again"|"next"|"stop"
function Queue:onEnded()
	if self.repeatMode == "one" then return "again" end
	if self.position < #self.order then
		self.position = self.position + 1
		return "next"
	end

	if self.repeatMode == "all" and #self.order > 0 then
		if self.shuffle then
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

function Queue:toggleShuffle()
	self.shuffle = not self.shuffle
	if self.shuffle then
		self:shuffleOrder()
	else
		local current = self.order[self.position]
		self.order = {}
		for at, index in ipairs(self.naturalOrder) do self.order[at] = index end
		if current ~= nil then
			for at, index in ipairs(self.order) do
					if index == current then
						self.position = at
						break
					end
				end
		end
	end
	return self.shuffle
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
		at = at + 1
	end
end

---@param tracks beat.Track[]
---@param index number?
function Queue:replace(tracks, index)
	self.tracks = tracks
	local order = {}
	local naturalOrder = {}
	for at = 1, #tracks do
			order[at] = at
			naturalOrder[at] = at
		end
	self.order = order
	self.naturalOrder = naturalOrder
	self.position = math.max(1, math.min(index or 1, #tracks))
	if self.shuffle then self:shuffleOrder() end
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
		source = self.source,
	}
end

local REPEAT_MODES = { off = true, all = true, one = true}

--- A packed queue put back, in the order it was in rather than a new shuffle. A track whose path
--- the library no longer has is left out; if that was the current one, the play head moves to the
--- first track after it that is still there. Nothing left is no queue.
---@param packed table
---@param find fun(path: string): beat.Track?
---@return beat.Queue?
---@return boolean # Whether the current track is the one that was current
function Queue.unpack(packed, find)
	if type(packed) ~= "table" or type(packed.tracks) ~= "table" or type(packed.order) ~= "table"
	or type(packed.naturalOrder) ~= "table" or type(packed.position) ~= "number" then
		return nil, false
	end

	local tracks, moved = {}, {}
	for at, path in ipairs(packed.tracks) do
		local track = type(path) == "string" and find(path) or nil
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
		if moved[packed.order[at]] ~= nil then before = before + 1 end
	end

	local queue = setmetatable({
	tracks = tracks,
	order = order,
	naturalOrder = remap(packed.naturalOrder),
	position = math.min(before + 1, #order),
	repeatMode = REPEAT_MODES[packed.repeatMode] and packed.repeatMode or "off",
	shuffle = packed.shuffle == true,
	source = type(packed.source) == "string" and packed.source or "library",
	}, Queue)

	return queue, moved[packed.order[packed.position]] ~= nil
end

return Queue
