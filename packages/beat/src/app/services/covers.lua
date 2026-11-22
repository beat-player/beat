-- The pictures the current screen is drawing.
--
-- This is not a cache of everything: it holds the covers that screens have asked for lately, keeps
-- a bounded number of them, decodes the ones a page asked for on threads of their own (so the
-- frame that asks for a cover draws a placeholder and a later one draws the art), and releases
-- every texture when the assets go away. Staying on a page does not decode anything twice.
local ffi = require("ffi")
local threading = require("threading")

-- Covers stay across page changes: going home again, or back to an album, must not decode and
-- upload the same picture again. The cache is bounded, oldest first, so browsing does not grow
-- it without end.
local CACHE_LIMIT = 48

-- How many covers decode at once. A decode is tens of milliseconds on a phone -- longer than a
-- frame -- which on the window's own thread is a list that stutters every time a row of albums
-- scrolls in; on threads of their own the window only uploads what comes back. Two keep a grid
-- filling quickly without taking every core from the rest of the machine.
local WORKERS = 2

local olderFirst = |a, b| -> a.seen < b.seen

---@class beat.CoverJob
---@field album beat.Album
---@field size number
---@field epoch number
---@field seen number

---@class beat.CoverEntry
---@field asset wonderland.Asset?
---@field colour { r: number, g: number, b: number }?
---@field failed boolean?
---@field seen number

---@class beat.CoversService: beat.Service
---@field assets wonderland.Assets?
---@field entries table<number, table<number, beat.CoverEntry>> # album id, then size
---@field count number # entries, kept as they are added and evicted
---@field onScreen number # entries this view asked for, so a frame over the limit knows if any is stale
---@field jobs beat.CoverJob[] # what the last view asked for and is still missing
---@field pending table<number, table<number, beat.CoverJob>> # album id, then size
---@field epoch number
---@field frame number # The view being built, which is what says a cover is still on screen
---@field decoding { job: beat.CoverJob, handle: threading.Handle }[] # Covers on a thread, in the order they started
local Covers = {}
Covers.__index = Covers
Covers.needs = {}

-- Nothing is needed: the window's assets arrive through `use` once the shell has a window to draw
-- in, not when the services are made.
---@return beat.CoversService
function Covers.new(_deps)
	return setmetatable({
		assets = nil,
		entries = {},
		count = 0,
		onScreen = 0,
		jobs = {},
		pending = {},
		epoch = 0,
		frame = 0,
		decoding = {}
	}, Covers)
end

---@param assets wonderland.Assets
function Covers:use(assets)
	if self.assets ~= assets then
		self:releaseAll()
		self.assets = assets
	end
end

--- A view is about to be built. Covers it asks for are kept; ones it does not ask for are
--- released by `sweep`, which is what keeps a scan's changing recently-added row from keeping a
--- texture for every album it ever showed.
function Covers:beginFrame()
	self.frame += 1
	self.onScreen = 0
end

--- Drops jobs for covers the view no longer asks for, and evicts the oldest cached covers once
--- the cache is over its limit. Covers still on screen are never evicted.
function Covers:sweep()
	local jobs = self.jobs
	local kept = 0
	for at = 1, #jobs do
		local job = jobs[at]
		if job.seen == self.frame then
			kept += 1
			jobs[kept] = job
		else
			local pending = self.pending[job.album.id]
			if pending ~= nil then
				pending[job.size] = nil
				if next(pending) == nil then self.pending[job.album.id] = nil end
			end
		end
	end
	for at = #jobs, kept + 1, -1 do jobs[at] = nil end

	-- A frame where every cached cover is one this view asked for has nothing to evict: two
	-- numbers settle it, without walking the cache.
	if self.count <= CACHE_LIMIT or self.count == self.onScreen then return end

	-- Only a frame that left covers behind while over the limit pays for a list of what could go
	-- and the sort that picks the oldest of it.
	local stale, staleCount = {}, 0
	for albumId, bySize in pairs(self.entries) do
		for size, entry in pairs(bySize) do
			if entry.seen ~= self.frame then
				staleCount += 1
				stale[staleCount] = { albumId = albumId, size = size, seen = entry.seen }
			end
		end
	end
	if staleCount == 0 then return end
	table.sort(stale, olderFirst)

	local over = math.min(self.count - CACHE_LIMIT, staleCount)
	local assets = self.assets
	for at = 1, over do
		local item = stale[at]
		local bySize = self.entries[item.albumId]
		local entry = bySize[item.size]
		if entry ~= nil then
			if entry.asset ~= nil and assets ~= nil then assets:release(entry.asset) end
			bySize[item.size] = nil
			self.count -= 1
			if next(bySize) == nil then self.entries[item.albumId] = nil end
		end
	end
end

--- The asset for one album's cover at one size, if it is ready, or nil while it decodes. Called
--- for every visible cover on every frame, so it looks a cover up by album id and size rather
--- than building a key for it and does not walk the jobs looking for one to mark as seen.
---@param album beat.Album
---@param size number
---@return wonderland.Asset?
function Covers:request(album, size)
	local albumId = album.id
	---@type table<number, beat.CoverEntry>?
	local bySize = self.entries[albumId]
	---@type beat.CoverEntry?
	local entry = bySize ~= nil and bySize[size] or nil
	if entry ~= nil then
		if entry.seen ~= self.frame then
			entry.seen = self.frame
			self.onScreen += 1
		end
		return entry.asset
	end

	local pending = self.pending[albumId]
	local job = pending ~= nil and pending[size] or nil
	if job ~= nil then
		job.seen = self.frame
		return nil
	end

	job = { album = album, size = size, epoch = self.epoch, seen = self.frame }
	if pending == nil then
		pending = {}
		self.pending[albumId] = pending
	end
	pending[size] = job
	self.jobs[#self.jobs + 1] = job

	return nil
end

---@param album beat.Album
---@return { r: number, g: number, b: number }?
function Covers:colourOf(album)
	---@type table<number, beat.CoverEntry>?
	local bySize = self.entries[album.id]
	if bySize == nil then return nil end
	for _, entry in pairs(bySize) do
		if entry.colour ~= nil then return entry.colour end
	end
	return nil
end

--- What a thread decodes: the cached cover of one album, fitted for one size, handed back as the
--- pixels the window uploads and the colour its page tints with.
---@param coverCache string
---@param size number
---@return threading.Handle
local function decodeOnThread(coverCache, size)
	return threading.spawn(function()
		local ffi = require("ffi")
		local artwork = require("beat.music.artwork")
		local fitted, colour = artwork.forAlbum({ coverCache = coverCache }, size)
		if fitted == nil then return nil end
		local width, height = fitted.width, fitted.height
		local pixels = ffi.string(fitted.pixels, width * height * 4)
		fitted:close()
		return width, height, pixels, colour
	end)
end

--- Starts what the view asked for, as threads come free, and uploads what they decoded. The job
--- list holds only covers the last view asked for, so what is on screen starts first. Busy while
--- covers are waiting or decoding, so the ticker comes back for them rather than at the idle
--- interval.
---@return boolean changed
---@return boolean busy
function Covers:step()
	local assets = self.assets
	if assets == nil then return false, #self.jobs > 0 end

	-- One cover is taken in a tick: what it costs the window is a texture upload and a rebuild of
	-- the view that shows it, and two of those in one frame are a frame that comes late. Another
	-- that has finished waits for the next tick, a frame away.
	local changed = false
	local decoding = self.decoding
	local kept = 0
	for at = 1, #decoding do
		local item = decoding[at]
		if not changed and item.handle:done() then
			self:finish(item.job, assets, pcall(item.handle.join, item.handle))
			changed = true
		else
			kept += 1
			decoding[kept] = item
		end
	end
	for at = #decoding, kept + 1, -1 do decoding[at] = nil end

	local jobs = self.jobs
	local started = 0
	while #decoding < WORKERS and started < #jobs do
		started += 1
		local job = jobs[started]
		local cache = job.album.coverCache
		if cache == nil then
			-- Not cached yet: a placeholder until the next scan, not a thread to find that out.
			self:finish(job, assets, true, nil)
			changed = true
		else
			decoding[#decoding + 1] = { job = job, handle = decodeOnThread(cache, job.size) }
		end
	end

	-- The started jobs leave the queue; what is left keeps the order the view asked for them in.
	if started > 0 then
		local left = #jobs
		for index = started + 1, left do jobs[index - started] = jobs[index] end
		for index = left - started + 1, left do jobs[index] = nil end
	end

	return changed, #jobs > 0 or #decoding > 0
end

--- What a thread came back with, into the cache: a texture, or a failure that is not tried again.
--- A cover for a library that has since been replaced, or an album that has since been forgotten,
--- is dropped.
---@param job beat.CoverJob
---@param assets wonderland.Assets
---@param ok boolean
---@param width number?
---@param height number?
---@param pixels string?
---@param colour { r: number, g: number, b: number }?
function Covers:finish(job, assets, ok, width, height, pixels, colour)
	local albumId, size = job.album.id, job.size
	local pending = self.pending[albumId]
	if pending ~= nil and pending[size] == job then
		pending[size] = nil
		if next(pending) == nil then self.pending[albumId] = nil end
	end
	if job.epoch ~= self.epoch then return end

	if ok and pixels ~= nil then
		-- The texture reads the bytes through a pointer; `pixels` holds them until it has.
		local bytes = ffi.cast("const uint8_t*", pixels)
		local asset = assets:upload({ width = width, height = height, channels = 4, pixels = bytes })
		self:store(albumId, size, { asset = asset, colour = colour, seen = job.seen })
	else
		-- A missing picture is normal; a broken one is only worth a single attempt.
		self:store(albumId, size, { failed = true, seen = job.seen })
	end
end

---@param albumId number
---@param size number
---@param entry beat.CoverEntry
function Covers:store(albumId, size, entry)
	local bySize = self.entries[albumId]
	if bySize == nil then
		bySize = {}
		self.entries[albumId] = bySize
		self.count += 1
	elseif bySize[size] == nil then
		self.count += 1
	end
	bySize[size] = entry
end

--- Drops what is known about one album, for when a later track brings its embedded picture.
---@param albumId number
function Covers:forget(albumId)
	local bySize = self.entries[albumId]
	if bySize ~= nil then
		if self.assets ~= nil then
			for _, entry in pairs(bySize) do
				if entry.asset ~= nil then self.assets:release(entry.asset) end
			end
		end
		for _ in pairs(bySize) do self.count -= 1 end
		self.entries[albumId] = nil
	end
	if self.pending[albumId] ~= nil then
		self.pending[albumId] = nil
		for at = #self.jobs, 1, -1 do
			if self.jobs[at].album.id == albumId then table.remove(self.jobs, at) end
		end
	end
	-- A cover still decoding is of the picture being forgotten: what it comes back with is dropped.
	for _, item in ipairs(self.decoding) do
		if item.job.album.id == albumId then item.job.epoch = -1 end
	end
end

function Covers:releaseAll()
	local assets = self.assets
	if assets ~= nil then
		for _, bySize in pairs(self.entries) do
			for _, entry in pairs(bySize) do
				if entry.asset ~= nil then assets:release(entry.asset) end
			end
		end
	end

	self.entries = {}
	self.count = 0
	self.onScreen = 0
	self.jobs = {}
	self.pending = {}
	self.epoch += 1
	self.frame = 0
end

return Covers
