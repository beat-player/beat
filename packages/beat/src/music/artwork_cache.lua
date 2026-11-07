-- Where decoded album covers live on this machine. The scan worker writes one small JPEG per
-- album here; the window only ever loads these local files, so a slow or remote music folder
-- never stalls a frame while a cover is being fetched. The folder is keyed by the library root,
-- so switching roots cannot make one scan prune another's art.
local fs = require("fs")
local path = require("path")
local md5 = require("beat.music.md5")

local artworkCache = {}

---@return string
local function baseDirectory()
	local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "."
	local osName = jit and jit.os or ""

	if osName == "Windows" then
		return path.join(os.getenv("LOCALAPPDATA") or path.join(home, "AppData", "Local"), "beat")
	elseif osName == "OSX" then
		return path.join(home, "Library", "Caches", "beat")
	end

	return path.join(os.getenv("XDG_CACHE_HOME") or path.join(home, ".cache"), "beat")
end

---@param root string
---@return string
function artworkCache.directory(root)
	return path.join(baseDirectory(), "covers", md5.sumhexa(root))
end

--- A stable file name for one source image. The modified time is part of the name, so a changed
--- picture is a new file rather than a stale one; old files are pruned after a complete scan.
---@param root string
---@param source string
---@param modified number?
---@param maxSide number
---@return string
function artworkCache.file(root, source, modified, maxSide)
	local key = source .. "\0" .. tostring(modified or 0) .. "\0" .. tostring(maxSide)

	return path.join(artworkCache.directory(root), md5.sumhexa(key) .. ".jpg")
end

--- Remove cached covers this scan did not use. Called only after a complete, successful scan:
--- a cancelled or failed scan must leave the previous cache alone.
---@param root string
---@param used table<string, boolean>
---@return number removed
function artworkCache.prune(root, used)
	local dir = artworkCache.directory(root)
	local iterator = fs.readdir(dir)
	if iterator == nil then return 0 end

	local removed = 0
	for entry in iterator do
			if entry.type == "file" then
				local file = path.join(dir, entry.name)
				if not used[file] then
					if fs.delete(file) then removed = removed + 1 end
				end
			end
		end

	return removed
end

return artworkCache
