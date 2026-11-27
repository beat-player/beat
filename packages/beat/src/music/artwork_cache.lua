-- Where decoded album covers live on this machine. The scan worker writes one small JPEG per
-- album here; the window only ever loads these local files, so a slow or remote music folder
-- never stalls a frame while a cover is being fetched. The folder is keyed by the library root,
-- so switching roots cannot make one scan prune another's art.
local fs = require("fs")
local path = require("path")
local threading = require("threading")
local md5 = require("beat.music.md5")

local artworkCache = {}

---@return string
local function baseDirectory()
	local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "."
	local osName = jit?.os or ""

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
				if fs.delete(file) then removed += 1 end
			end
		end
	end

	return removed
end

-- Prunes still running, joined when the next one starts so their thread state is given back. A
-- prune is a readdir and a delete per stale cover: work the scan's last tick, with a library to
-- finish and a cache to save, should not hold a frame for.
---@type threading.Handle[]
local pruning = {}

local function reapPruning()
	for at = #pruning, 1, -1 do
		local handle = pruning[at]
		if handle:done() then
			pcall(handle.join, handle)
			table.remove(pruning, at)
		end
	end
end

--- Prunes the covers a completed scan did not use, on a thread of its own. The answer is the
--- thread's handle, which the next prune joins; a caller that must wait for it (a test, shutdown)
--- can join it itself and read how many files went.
---@param root string
---@param used table<string, boolean>
---@return threading.Handle? handle
---@return string? err
function artworkCache.pruneAsync(root, used)
	reapPruning()

	local ok, handle = pcall(threading.spawn, function()
		return require("beat.music.artwork_cache").prune(root, used)
	end)
	if not ok then return nil, tostring(handle) end

	pruning[#pruning + 1] = handle
	return handle
end

return artworkCache
