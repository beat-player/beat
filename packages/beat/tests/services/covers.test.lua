-- The cover worker gives the window pixels as an address in memory the window frees, not as a
-- Lua string: these tests watch the buffers that cross, and read the pixels through the address
-- where the upload would read them, before the free.
local test = require("lde-test")
local ffi = require("ffi")
local fs = require("fs")
local image = require("image")
local threading = require("threading")
local time = require("wonderland.time")
local coverPixels = require("beat.music.cover_pixels")
local Covers = require("beat.app.services.covers")

local root = os.tmpname() .. "-beat-cover-pixels"
fs.mkdirAll(root)

test.afterAll(function()
	fs.rmdir(root)
end)

local realAlloc, realFree = coverPixels.alloc, coverPixels.free

-- One buffer is outstanding when the bytes it holds have not been given back, and a decode that
-- returns is balanced when both reach zero again.
local liveBytes, liveCount, freedCount = 0, 0, 0
local sizes = {}

--- Watches both sides: what this state allocates and frees -- the decode run in place, and the
--- buffers a fake service answer holds -- so an unbalanced path is a number rather than a leak in
--- a process that ends.
local function watchAllocations()
	coverPixels.alloc = function(bytes)
		local address = realAlloc(bytes)
		if address ~= nil then
			sizes[address] = bytes
			liveBytes += bytes
			liveCount += 1
		end
		return address
	end
	coverPixels.free = function(address)
		if address ~= nil then
			freedCount += 1
			local bytes = sizes[address]
			if bytes ~= nil then
				sizes[address] = nil
				liveBytes -= bytes
				liveCount -= 1
			end
		end
		return realFree(address)
	end
end

--- Watches the window's side of a real worker, whose allocation happened in the worker's state
--- and is therefore not this state's to count: every answer that comes back must still be freed
--- exactly once.
local function watchFrees()
	coverPixels.free = function(address)
		if address ~= nil then freedCount += 1 end
		return realFree(address)
	end
end

test.afterEach(function()
	coverPixels.alloc = realAlloc
	coverPixels.free = realFree
	liveBytes, liveCount, freedCount = 0, 0, 0
	sizes = {}
end)

---@param name string
local function coverFile(name)
	local file = root .. "/" .. name .. ".png"
	local source = image.new(16, 16, 4)
	source:fill(10, 20, 30, 255)
	assert(fs.write(file, assert(source:encode("png"))))
	source:close()
	return file
end

---@param onUpload fun(decoded: { width: number, height: number, pixels: ffi.cdata* })?
---@return { upload: fun(self: any, decoded: any): any, release: fun(self: any, asset: any): any }
local function assetsWith(onUpload)
	return {
		upload = function(_, pixels)
			local decoded = pixels --[[@as { width: number, height: number, pixels: ffi.cdata* }]]
			if onUpload ~= nil then onUpload(decoded) end
			return { width = decoded.width, height = decoded.height, texture = 0 }
		end,
		release = function() end
	}
end

--- A scroll service that is never moving, so a step decodes and joins instead of waiting for a
--- page to settle.
---@return beat.ScrollService
local function idleScroll()
	return { isMoving = function() return false end } --[[@as beat.ScrollService]]
end

--- The only part of an album the cover service reads.
---@param id number
---@param file string
---@return beat.Album
local function album(id, file)
	return { id = id, coverCache = file } --[[@as beat.Album]]
end

local function coversService()
	local covers = Covers.new({ scroll = idleScroll() })
	covers:use(assetsWith() --[[@as wonderland.Assets]])
	covers:beginFrame()
	return covers
end

--- Steps the service until it is quiet, as the ticker would, without assuming a decode is quick.
---@param covers beat.CoversService
---@return boolean ok # False when the deadline passed with work still running
local function settle(covers)
	local deadline = time.now() + 10
	while time.now() < deadline do
		local _, busy = covers:step(0)
		if not busy then return true end
		threading.sleep(1)
	end
	return false
end

--- Starts the queued cover on a worker and waits for it to finish, without joining it: what a
--- test needs to reach the paths that only run once an answer is waiting.
---@param covers beat.CoversService
---@return boolean ok
local function startAndWaitForDecode(covers)
	covers:step(0)
	local deadline = time.now() + 10
	while time.now() < deadline do
		local item = covers.decoding[1]
		if item ~= nil and item.handle ~= nil and item.handle:done() then return true end
		threading.sleep(1)
	end
	return false
end

test.it("decodes into one buffer and frees it once", function()
	watchAllocations()
	local file = coverFile("square")

	local width, height, address, colour = coverPixels.decode(file, 16)
	test.equal(width, 16)
	test.equal(height, 16)
	test.equal(liveCount, 1, "the decode allocated exactly one buffer")
	test.equal(liveBytes, 16 * 16 * 4)

	local pixels = coverPixels.pointer(address --[[@as string]])
	test.equal(pixels[0], 10)
	test.equal(pixels[1], 20)
	test.equal(pixels[2], 30)
	test.equal(pixels[3], 255)
	test.equal(math.floor(colour.r * 255 + 0.5), 10)

	coverPixels.free(address)
	test.equal(liveCount, 0)
	test.equal(liveBytes, 0)
end)

test.it("uploads a worker's pixels from their address and frees them after", function()
	watchFrees()
	local file = coverFile("threaded")
	local seen = {}
	local covers = Covers.new({ scroll = idleScroll() })
	covers:use(assetsWith(function(decoded)
		local pixels = ffi.cast("uint8_t*", decoded.pixels)
		seen = { decoded.width, decoded.height, pixels[0], pixels[1], pixels[2], pixels[3] }
	end) --[[@as wonderland.Assets]])

	covers:beginFrame()
	test.equal(covers:request(album(1, file), 16), nil)
	test.truthy(settle(covers), "the worker decoded the cover")
	test.equal(#seen, 6)
	test.equal(seen[1], 16)
	test.equal(seen[2], 16)
	test.equal(seen[3], 10)
	test.equal(seen[4], 20)
	test.equal(seen[5], 30)
	test.equal(seen[6], 255)
	test.equal(freedCount, 1, "the uploaded buffer was given back once")
	test.truthy(covers:request(album(1, file), 16) ~= nil, "the cover is cached")
	covers:close()
end)

test.it("frees a decode the view has scrolled past", function()
	watchFrees()
	local file = coverFile("forgotten")
	local covers = coversService()

	covers:request(album(7, file), 16)
	test.truthy(startAndWaitForDecode(covers), "the worker decoded the cover")
	covers:forget(7)
	test.truthy(settle(covers), "the worker was joined")
	test.equal(freedCount, 1, "the dropped cover's pixels were given back")
	test.equal(covers:request(album(7, file), 16), nil, "a forgotten cover is requested again")
	covers:close()
end)

test.it("frees pixels still on a worker when the service closes", function()
	watchFrees()
	local file = coverFile("closing")
	local covers = coversService()

	covers:request(album(8, file), 16)
	test.truthy(startAndWaitForDecode(covers), "the worker decoded the cover")
	covers:close()
	test.equal(freedCount, 1, "closing joined the decode and gave its pixels back")
end)

test.it("frees before raising when the upload fails", function()
	watchFrees()
	local file = coverFile("failing")
	local covers = Covers.new({ scroll = idleScroll() })
	covers:use({
		upload = function() error("the texture was refused") end,
		release = function() end
	} --[[@as wonderland.Assets]])

	covers:beginFrame()
	covers:request(album(9, file), 16)
	test.truthy(startAndWaitForDecode(covers), "the worker decoded the cover")
	local ok = pcall(covers.step, covers, 0)
	test.falsy(ok, "the upload error reached the caller")
	test.equal(freedCount, 1, "the buffer was given back before the error")
	covers:close()
	test.equal(freedCount, 1, "the joined handle was not freed twice")
end)

test.it("frees a buffer whose upload was dropped after joining", function()
	watchAllocations()
	local covers = coversService()
	local job = { album = album(10, "unused"), size = 16, epoch = 0, seen = 1 } --[[@as beat.CoverJob]]
	covers.frame = 1
	covers.pending[10] = { [16] = job }
	covers.jobs[1] = job

	local address = coverPixels.alloc(16 * 16 * 4)
	test.truthy(address ~= nil, "a buffer to hand over")
	covers.frame = 2
	test.falsy(covers:finish(job, covers.assets --[[@as wonderland.Assets]], true, 16, 16, address, nil), "a stale cover is dropped")
	test.equal(liveCount, 0)
	test.equal(liveBytes, 0)
	covers:close()
end)
