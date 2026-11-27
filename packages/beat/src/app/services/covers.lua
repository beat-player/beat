-- The pictures the current screen is drawing.
--
-- This is not a cache of everything: it holds the covers that screens have asked for lately, keeps
-- a bounded number of them, decodes the ones a page asked for on a small pool of worker threads
-- (so the frame that asks for a cover draws a placeholder and a later one draws the art), and
-- releases every texture when the assets go away. Staying on a page does not decode anything
-- twice. While the list is moving, nothing is uploaded or started: the frames a finger is waiting
-- for carry only the cheap placeholder, and the queue of visible covers is decoded once it settles.
local threading = require("threading")
local artwork = require("beat.music.artwork")
local coverPixels = require("beat.music.cover_pixels")

-- Covers stay across page changes: going home again, or back to an album, must not decode and
-- upload the same picture again. What is kept is what the last frame asked for plus a small
-- margin, oldest first, so a page change gives back the pictures the new page does not show.
-- A phone's cover is near a megabyte of texture, and a fixed limit of several dozen was tens of
-- megabytes of GPU memory held for pages that had already gone. Four are enough that a scroll
-- turned back over the rows it just left finds their pictures still here: the bench's own scroll,
-- and one that goes down and back up, ask for no cover it had already decoded.
local CACHE_MARGIN = 4

-- How long a window that is not showing keeps the pictures it was showing. A cover given back is
-- a texture freed and a decode to pay for when it is asked for again -- tens of milliseconds on a
-- phone, which is a screen that comes back with holes in it. A minimize or an app switch is
-- usually shorter than this; a window left in the tray for half a minute is not coming back to
-- the pictures it was on, so they are worth more as memory than as a cache.
local HIDDEN_RELEASE = 30

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
---@field scroll beat.ScrollService
---@field assets wonderland.Assets?
---@field entries table<number, table<number, beat.CoverEntry>> # album id, then size
---@field count number # entries, kept as they are added and evicted
---@field onScreen number # entries this view asked for, so a frame over the limit knows if any is stale
---@field jobs beat.CoverJob[] # what the last view asked for and is still missing
---@field pending table<number, table<number, beat.CoverJob>> # album id, then size
---@field epoch number
---@field frame number # The view being built, which is what says a cover is still on screen
---@field pool threading.Pool? # The threads covers decode on, made when the first one is needed
---@field decoding { job: beat.CoverJob, handle: threading.PoolHandle }[] # Covers on a worker, in the order they started
---@field hiddenSince number? # When the window stopped showing, while it has not shown again
---@field notShowing boolean? # Whether the window is not showing, release or no release
---@field releasedWhileHidden boolean? # Whether the last hidden stretch gave the textures back
local Covers = {}
Covers.__index = Covers
Covers.needs = { "scroll" }

--- What a worker decodes: the cached cover of one album, fitted for one size, handed back as the
--- address of pixels the window frees and the colour its page tints with. The function takes its
--- job as arguments rather than closing over them, because one worker runs many covers: its Lua
--- state, the modules it requires and the traces JIT compiled for the image work all stay warm.
--- The pixels are a buffer the worker allocates rather than a Lua string, so crossing back into
--- the window copies no picture onto its heap. See `beat.music.cover_pixels`.
---@param coverCache string
---@param size number
---@param source { path: string, hasPicture: boolean, coverPath: string?, modified: number? }?
---@return number? width
---@return number? height
---@return string? address
---@return { r: number, g: number, b: number }? colour
local function decodeCover(coverCache, size, source)
	local pixels = require("beat.music.cover_pixels")
	return pixels.decode(coverCache, size, source)
end

---@param deps { scroll: beat.ScrollService }
---@return beat.CoversService
function Covers.new(deps)
	return setmetatable({
		scroll = deps.scroll,
		assets = nil,
		entries = {},
		count = 0,
		onScreen = 0,
		jobs = {},
		pending = {},
		epoch = 0,
		frame = 0,
		pool = nil,
		decoding = {},
		hiddenSince = nil,
		notShowing = nil,
		releasedWhileHidden = nil
	}, Covers)
end

--- The workers, made when a cover first needs one: an app that opens on a text page should not
--- have two threads waiting for it, and a test that never decodes a cover starts none.
---@return threading.Pool
function Covers:workers()
	local pool = self.pool
	if pool == nil then
		pool = threading.pool(WORKERS, decodeCover)
		self.pool = pool
	end
	---@cast pool -nil
	return pool
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

	-- What the view is drawing plus a margin is what the cache may hold. A frame where every
	-- cached cover is one this view asked for has nothing to evict: two numbers settle it,
	-- without walking the cache.
	local limit = self.onScreen + CACHE_MARGIN
	if self.count <= limit or self.count == self.onScreen then return end

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

	local over = math.min(self.count - limit, staleCount)
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

--- Starts what the view asked for, as workers come free, and uploads what they decoded. The job
--- list holds only covers the last view asked for, so what is on screen starts first. Busy while
--- covers are waiting or decoding, so the ticker comes back for them rather than at the idle
--- interval.
---
--- While the page is scrolling, nothing is taken in and nothing is started: a texture upload and
--- the view rebuild that shows it are exactly the work a moving list cannot afford. Finished
--- decodes wait on their workers. Once the page settles the next tick joins them -- dropping the
--- ones the view has scrolled past -- and the visible covers decode on the workers that are left.
---@param now number
---@return boolean changed
---@return boolean busy
function Covers:step(now)
	-- A hidden window keeps its pictures for a while: a quick minimize or app switch comes back
	-- to the art it was showing instead of a page of placeholders while the decodes run. Only a
	-- window hidden long enough gives the textures back.
	local since = self.hiddenSince
	if since ~= nil and now - since >= HIDDEN_RELEASE then
		self.hiddenSince = nil
		self.releasedWhileHidden = true
		self:releaseAll()
	end

	-- A window that is not showing draws no cover: joining a decode would upload a texture nobody
	-- sees and starting one spends a worker on the same. What was already decoding stays on its
	-- worker; the first step after the window shows again joins and starts it.
	if self.notShowing then return false, false end

	local assets = self.assets
	if assets == nil then return false, #self.jobs > 0 end
	if self.scroll:isMoving(now) then return false, #self.jobs > 0 or #self.decoding > 0 end

	-- One cover is taken in a tick: what it costs the window is a texture upload and a rebuild of
	-- the view that shows it, and two of those in one frame are a frame that comes late. Another
	-- that has finished waits for the next tick, a frame away. A decode the view no longer wants
	-- is not stored, so it costs only the join and does not count against that budget.
	local changed = false
	local stored = false
	local decoding = self.decoding
	local kept = 0
	for at = 1, #decoding do
		local item = decoding[at]
		local keep = true
		-- Taken out before the join, so a failure in the upload that follows cannot leave a handle
		-- whose answer -- and with it the address of pixels already freed -- can be joined again.
		local handle = item.handle
		if handle ~= nil and handle:done() then
			if not stored then
				item.handle = nil
				if self:finish(item.job, assets, pcall(handle.join, handle)) then
					changed = true
					stored = true
				end
				keep = false
			end
		end
		if keep then
			kept += 1
			decoding[kept] = item
		end
	end
	for at = #decoding, kept + 1, -1 do decoding[at] = nil end

	local jobs = self.jobs
	local started = 0
	---@type threading.Pool?
	local pool = nil
	while #decoding < WORKERS and started < #jobs do
		local job = jobs[started + 1]
		local cache = job.album.coverCache
		if cache == nil then
			-- Nothing has ever been cached for this album, so there is no file to make again and
			-- no path to put one at: a placeholder until a scan reads the folder. Still a store
			-- and a rebuild, so it waits its turn like a decoded cover.
			if stored then break end
			started += 1
			if self:finish(job, assets, true, nil) then changed = true end
			stored = true
		else
			pool = pool or self:workers()
			local handle = pool:run(cache, job.size, artwork.source(job.album) or {})
			if handle == nil then break end
			started += 1
			decoding[#decoding + 1] = { job = job, handle = handle }
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

--- What a worker came back with, into the cache: a texture, or a failure that is not tried again.
--- A cover for a library that has since been replaced, an album that has since been forgotten, or
--- one the view scrolled past before it finished is dropped: the decode is already spent, and
--- uploading a texture nothing draws is the part that would cost the next frame.
---
--- Whatever happens here, the pixels the worker allocated are given back: the upload reads them
--- once into the texture's staging memory, and a cover that is dropped or whose upload fails must
--- not leave a buffer behind.
---@param job beat.CoverJob
---@param assets wonderland.Assets
---@param ok boolean
---@param width number?
---@param height number?
---@param address string?
---@param colour { r: number, g: number, b: number }?
---@return boolean stored # False when the cover was dropped without becoming an entry
function Covers:finish(job, assets, ok, width, height, address, colour)
	local albumId, size = job.album.id, job.size
	local pending = self.pending[albumId]
	if pending ~= nil and pending[size] == job then
		pending[size] = nil
		if next(pending) == nil then self.pending[albumId] = nil end
	end
	if job.epoch ~= self.epoch or job.seen ~= self.frame then
		coverPixels.free(address)
		return false
	end

	if ok and address ~= nil then
		local uploaded, asset = pcall(assets.upload, assets, {
			width = width,
			height = height,
			channels = 4,
			pixels = coverPixels.pointer(address)
		})
		coverPixels.free(address)
		if not uploaded then error(asset, 0) end
		self:store(albumId, size, { asset = asset, colour = colour, seen = job.seen })
	else
		-- A missing picture is normal; a broken one is only worth a single attempt.
		coverPixels.free(address)
		self:store(albumId, size, { failed = true, seen = job.seen })
	end
	return true
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

--- Drops the remembered failures, so the next frame asks for those covers again. A scan that
--- rebuilt a cache -- including one made after the cache directory was cleaned -- can make good on
--- a cover this service had found missing; without this, a page that was open while it happened
--- would keep the placeholder it stored for good.
function Covers:retryFailed()
	for albumId, bySize in pairs(self.entries) do
		for size, entry in pairs(bySize) do
			if entry.failed then
				bySize[size] = nil
				self.count -= 1
			end
		end
		if next(bySize) == nil then self.entries[albumId] = nil end
	end
end

--- The window stopped showing: when it started matters only after a while, so the pictures stay
--- for now and a tick is what gives them back if the window stays away. See `HIDDEN_RELEASE`.
---@param now number
function Covers:hidden(now)
	self.notShowing = true
	if self.hiddenSince == nil then self.hiddenSince = now end
end

--- The window is showing again. Answers whether its last hidden stretch was long enough that the
--- pictures were given back, which is a screen that has to be built rather than only drawn: the
--- covers it shows are asked for again by the view, and decoded then.
---@return boolean released
function Covers:shown()
	local released = self.releasedWhileHidden == true
	self.notShowing = false
	self.hiddenSince = nil
	self.releasedWhileHidden = nil
	return released
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

--- The app is going or being set up again: a warm worker state is no longer worth keeping. A
--- cover still decoding is dropped with the pool rather than uploaded into assets that are gone;
--- joining it here is what lets the pixels it allocated be given back, which the pool's own close
--- cannot do because it only knows the answer as bytes it throws away.
function Covers:close()
	local decoding = self.decoding
	for at = 1, #decoding do
		local handle = decoding[at].handle
		if handle ~= nil then
			local ok, _, _, address = pcall(handle.join, handle)
			if ok then coverPixels.free(address --[[@as string?]]) end
		end
	end
	self.decoding = {}

	local pool = self.pool
	if pool ~= nil then
		self.pool = nil
		pool:close()
	end
	self:releaseAll()
end

return Covers
