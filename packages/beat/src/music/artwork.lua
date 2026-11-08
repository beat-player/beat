-- Artwork: the decoded picture, a square copy small enough for a texture, and the colour it is
-- mostly made of. A cover arrives at whatever size the tagger put in the file; a screen needs a
-- few hundred pixels of it. This is the one place that knows both.
local ffi = require("ffi")
local image = require("image")
local fs = require("fs")
local path = require("path")
local audio = require("treble.audio")
local artworkCache = require("beat.music.artwork_cache")

local artwork = {}

local u8 = ffi.typeof("uint8_t*")

---@param picture treble.Tags.Picture
---@return image.Image?
---@return string?
function artwork.decode(picture)
	return image.decode(picture.data, { channels = 4})
end

---@param bytes string
---@return image.Image?
---@return string?
function artwork.decodePNG(bytes)
	return image.decode(bytes, { channels = 4})
end

---@param path string
---@return image.Image?
---@return string?
function artwork.load(path)
	return image.load(path, { channels = 4})
end

--- A square, centred copy no larger than `maxSide`. The source keeps its aspect ratio by being
--- cropped, which is what a cover grid wants: letterboxed art reads as a mistake.
---@param source image.Image
---@param maxSide number
---@return image.Image
function artwork.fit(source, maxSide)
	local side = math.min(source.width, source.height)
	local target = math.min(maxSide, side)
	local left = math.floor((source.width - side) / 2)
	local top = math.floor((source.height - side) / 2)
	local channels = source.channels
	local from = ffi.cast(u8, source.pixels)
	local result = image.new(target, target, 4)
	local into = ffi.cast(u8, result.pixels)

	if target == side and channels == 4 then
		-- A cropped side is still a window of a wider source: copying it as one run would take
		-- the row after the crop from wherever the previous row left off. Each row is copied
		-- from its own start instead.
		for row = 0, side - 1 do
			ffi.copy(into + row * side * 4, from + ((top + row) * source.width + left) * 4, side * 4)
		end
		return result
	end

	for y = 0, target - 1 do
		local y0 = top + math.floor(y * side / target)
		local y1 = top + math.floor((y + 1) * side / target)
		if y1 <= y0 then y1 = y0 + 1 end

		for x = 0, target - 1 do
			local x0 = left + math.floor(x * side / target)
			local x1 = left + math.floor((x + 1) * side / target)
			if x1 <= x0 then x1 = x0 + 1 end

			local r, g, b, a = 0, 0, 0, 0
			local count = 0
			-- A 3000-pixel cover down to a 160-pixel card would average hundreds of source
			-- pixels per destination pixel in Lua. Sixteen samples per cell is plenty once
			-- the texture is sampled linearly, and it keeps a cover from stalling a frame.
			local stepX = math.max(1, math.floor((x1 - x0) / 4))
			local stepY = math.max(1, math.floor((y1 - y0) / 4))

			for sy = y0, y1 - 1, stepY do
				local row = sy * source.width
				for sx = x0, x1 - 1, stepX do
					local at = (row + sx) * channels
					r += from[at]
					g += from[at + 1]
					b += from[at + 2]
					a += (channels >= 4 and from[at + 3] or 255)
					count += 1
				end
			end

			local at = (y * target + x) * 4
			into[at] = math.floor(r / count + 0.5)
			into[at + 1] = math.floor(g / count + 0.5)
			into[at + 2] = math.floor(b / count + 0.5)
			into[at + 3] = math.floor(a / count + 0.5)
		end
	end

	return result
end

--- The colour an album page tints itself with, as channels from zero to one. Sampling a small
--- square rather than every pixel is enough: artwork's palette is not a histogram problem.
---@param source image.Image
---@return number r
---@return number g
---@return number b
function artwork.dominant(source)
	local pixels = ffi.cast(u8, source.pixels)
	local step = math.max(1, math.floor(math.min(source.width, source.height) / 12))
	local r, g, b, count = 0, 0, 0, 0

	for y = 0, source.height - 1, step do
		for x = 0, source.width - 1, step do
			local at = (y * source.width + x) * source.channels
			r += pixels[at]
			g += pixels[at + 1]
			b += pixels[at + 2]
			count += 1
		end
	end

	if count == 0 then return 0.2, 0.2, 0.2 end
	return (r / count) / 255, (g / count) / 255, (b / count) / 255
end

--- Reads the art a file or its folder holds, decodes it, and returns a fitted image with its
--- dominant colour. The source is closed before this returns; the caller owns the result.
---@param track beat.Track
---@param maxSide number
---@return image.Image? fitted
---@return { r: number, g: number, b: number }? colour
---@return string? err
function artwork.forTrack(track, maxSide)
	local decoded, err

	if track.hasPicture then
		local tags = audio.tags(track.path)
		if tags?.picture ~= nil then
			decoded, err = image.decode(tags.picture.data, { channels = 4})
		end
	end

	-- A picture inside the track is preferred, but a picture beside it is still better than a
	-- placeholder when the tag reader or the embedded image cannot handle it.
	if decoded == nil and track.coverPath ~= nil then
		decoded, err = image.load(track.coverPath, { channels = 4})
	end

	if decoded == nil then
		return nil, nil, err or "no artwork"
	end

	---@cast decoded image.Image
	local fitted = artwork.fit(decoded, maxSide)
	local r, g, b = artwork.dominant(fitted)
	decoded:close()

	return fitted, { r = r, g = g, b = b}
end

--- Downscale one track's art and write it to the local cache. The scan worker calls this while
--- reading the remote library; the window then loads only the returned file. The source's
--- modified time is part of the cache name, so a changed picture is a different cache entry.
---@param track { path: string, hasPicture: boolean, coverPath: string?, modified: number?, coverModified: number? }
---@param maxSide number
---@param root string
---@return string? file
---@return string? err
function artwork.cacheCover(track, maxSide, root)
	local source = track.hasPicture and track.path or track.coverPath
	if source == nil then return nil, "no artwork" end

	local modified = track.hasPicture and track.modified or (track.coverModified or track.modified)
	local file = artworkCache.file(root, source, modified, maxSide)
	if fs.isfile(file) then return file, nil end

	local fitted, _, err = artwork.forTrack(track, maxSide)
	if fitted == nil then return nil, err end

	local folder = path.dirname(file)
	if not fs.isdir(folder) then
		fs.mkdirAll(folder)
		if not fs.isdir(folder) then
			fitted:close()
			return nil, "cannot create " .. folder
		end
	end

	local encoded, encodeErr = fitted:encode("jpg", { quality = 90})
	fitted:close()
	if encoded == nil then return nil, encodeErr end

	-- Inspectors may race for the same album's cache file when an album spans folders. Write a
	-- sibling temporary and rename it into place, so a reader never sees a partial JPEG.
	local temp = file .. "." .. tostring(os.time()) .. "." .. tostring(math.random(1, 1000000)) .. ".tmp"
	if not fs.write(temp, encoded) then return nil, "cannot write " .. temp end
	local moved, moveErr = fs.move(temp, file)
	if not moved then
		fs.delete(temp)
		return nil, moveErr or ("cannot move " .. temp)
	end

	return file, nil
end

--- The cached cover for an album, fitted for this screen. The window never reads the music folder
--- here: the scan worker has already produced the local file, and a missing one is a placeholder
--- until the next scan rather than a blocking read of a remote file.
---@param album beat.Album
---@param maxSide number
---@return image.Image? fitted
---@return { r: number, g: number, b: number }? colour
---@return string? err
function artwork.forAlbum(album, maxSide)
	local cache = album.coverCache
	if cache == nil then return nil, nil, "cover has not been cached yet" end

	local decoded, err = image.load(cache, { channels = 4})
	if decoded == nil then return nil, nil, err end

	local fitted = artwork.fit(decoded, maxSide)
	local r, g, b = artwork.dominant(fitted)
	decoded:close()

	return fitted, { r = r, g = g, b = b}
end

--- What a file says about a picture it holds, before decoding it.
---@param path string
---@return image.Info?
---@return string?
function artwork.probeFile(path)
	local bytes = fs.read(path)
	if bytes == nil then return nil, "cannot read " .. path end
	return image.probe(bytes, path)
end

return artwork
