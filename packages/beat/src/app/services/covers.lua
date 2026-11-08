-- The pictures the current screen is drawing.
--
-- This is not a cache. It holds exactly the covers the page on screen asked for, decodes them one
-- tick at a time (so the frame that asks for a cover draws a placeholder and the next one draws
-- the art), and releases every texture when the page goes away. Nothing survives navigation.
local artwork = require("beat.music.artwork")

-- Covers stay across page changes: going home again, or back to an album, must not decode and
-- upload the same picture again. The cache is bounded, oldest first, so browsing does not grow
-- it without end.
local CACHE_LIMIT = 48

---@class beat.CoversService: beat.Service
---@field assets wonderland.Assets?
---@field entries table<string, { asset: wonderland.Asset?, colour: { r: number, g: number, b: number }?, failed: boolean?, seen: number }>
---@field jobs { key: string, album: beat.Album, size: number, epoch: number, seen: number }[]
---@field epoch number
---@field frame number # The view being built, which is what says a cover is still on screen
---@field jobsByKey table<string, boolean>
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
		jobs = {},
		epoch = 0,
		frame = 0,
		jobsByKey = {},
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
	self.frame = self.frame + 1
end

--- Drops jobs for covers the view no longer asks for, and evicts the oldest cached covers once
--- the cache is over its limit. Covers still on screen are never evicted.
function Covers:sweep()
	for at = #self.jobs, 1, -1 do
		local job = self.jobs[at]
		if job.seen ~= self.frame then
			self.jobsByKey[job.key] = nil
			table.remove(self.jobs, at)
		end
	end

	local count = 0
	for _ in pairs(self.entries) do count = count + 1 end
	if count <= CACHE_LIMIT then return end

	local stale = {}
	for key, entry in pairs(self.entries) do
		if entry.seen ~= self.frame then stale[#stale + 1] = { key = key, seen = entry.seen} end
	end
	table.sort(stale, function(a, b) return a.seen < b.seen end)

	local over = count - CACHE_LIMIT
	for at = 1, math.min(over, #stale) do
		local key = stale[at].key
		local entry = self.entries[key]
		if entry ~= nil then
			if entry.asset ~= nil and self.assets ~= nil then self.assets:release(entry.asset) end
			self.entries[key] = nil
		end
	end
end

---@param album beat.Album
---@param size number
---@return wonderland.Asset?
function Covers:request(album, size)
	local key = tostring(album.id) .. ":" .. tostring(size)
	local known = self.entries[key]

	if known ~= nil then
		known.seen = self.frame
		return known.asset
	end

	if not self.jobsByKey[key] then
		self.jobsByKey[key] = true
		self.jobs[#self.jobs + 1] = {
			key = key,
			album = album,
			size = size,
			epoch = self.epoch,
			seen = self.frame,
		}
	else
		for at = 1, #self.jobs do
			if self.jobs[at].key == key then
				self.jobs[at].seen = self.frame
				break
			end
		end
	end

	return nil
end

---@param album beat.Album
---@return { r: number, g: number, b: number }?
function Covers:colourOf(album)
	local prefix = tostring(album.id) .. ":"
	for key, entry in pairs(self.entries) do
		if key:sub(1, #prefix) == prefix then return entry.colour end
	end
	return nil
end

--- One decode per tick. A cover is a few milliseconds; doing one keeps a grid's first frame
--- responsive while the rest of the page is already laid out. Busy while covers are waiting, so
--- the ticker comes back for the next one rather than at the idle interval.
---@return boolean changed
---@return boolean busy
function Covers:step()
	if self.assets == nil or #self.jobs == 0 then return false, #self.jobs > 0 end

	local job = table.remove(self.jobs, 1)
	self.jobsByKey[job.key] = nil
	if job.epoch ~= self.epoch then return true, #self.jobs > 0 end

	local fitted, colour, err = artwork.forAlbum(job.album, job.size)
	if fitted ~= nil then
		---@cast fitted image.Image
		local asset = self.assets:upload(fitted)
		fitted:close()
		self.entries[job.key] = { asset = asset, colour = colour, seen = job.seen}
	else
		self.entries[job.key] = { failed = true, colour = nil, seen = job.seen}
		if err ~= nil and err ~= "no artwork" then
			-- A missing picture is normal; a broken one is only worth a single attempt.
			self.entries[job.key].failed = true
		end
	end

	return true, #self.jobs > 0
end

--- Drops what is known about one album, for when a later track brings its embedded picture.
---@param albumId number
function Covers:forget(albumId)
	local prefix = tostring(albumId) .. ":"
	for key, entry in pairs(self.entries) do
		if key:sub(1, #prefix) == prefix then
			if entry.asset ~= nil and self.assets ~= nil then self.assets:release(entry.asset) end
			self.entries[key] = nil
		end
	end
	for at = #self.jobs, 1, -1 do
		local job = self.jobs[at]
		if job.album.id == albumId then
			self.jobsByKey[job.key] = nil
			table.remove(self.jobs, at)
		end
	end
end

function Covers:releaseAll()
	if self.assets ~= nil then
		for _, entry in pairs(self.entries) do
			if entry.asset ~= nil then self.assets:release(entry.asset) end
		end
	end

	self.entries = {}
	self.jobsByKey = {}
	self.jobs = {}
	self.epoch = self.epoch + 1
	self.frame = 0
end

return Covers
