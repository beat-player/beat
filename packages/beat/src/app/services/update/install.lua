-- Updating beat means putting a new program where the running one is. Windows will not let a
-- running executable be overwritten and elsewhere the old image has to be swapped atomically, so
-- the release zip is unpacked in the config directory first, and only then is the executable
-- replaced and a fresh copy started. A source run has no executable of its own to replace -- the
-- process is the `lde` runtime -- and a phone's APK belongs to the system installer, so both are
-- reported instead of half-done.
local fs = require("fs")
local path = require("path")
local env = require("env")
local paths = require("beat.paths")
local platform = require("beat.platform")
local instance = require("beat.instance")
local Log = require("beat.log")

local install = {}

-- What unpacks a zip when neither unzip nor a zip-capable tar is on the machine. It is a single
-- line because a shell command has to carry it; the arguments are the archive and the directory.
local PYTHON_EXTRACT = "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])"

---@param value string
local function quotePosix(value)
	return "'" .. value:gsub("'", "'\\''") .. "'"
end

---@param value string
local function quoteWindows(value)
	return '"' .. value:gsub('"', '""') .. '"'
end

--- The shell commands that unpack a release zip, in the order they are tried. They are built as
--- strings rather than run here so a test can read exactly what a path turns into.
---@param osName string
---@param zipPath string
---@param dir string
---@return string[]
function install._commands(osName, zipPath, dir)
	local quote = osName == "Windows" and quoteWindows or quotePosix
	local python = osName == "Windows" and ('"' .. PYTHON_EXTRACT .. '"') or ("'" .. PYTHON_EXTRACT .. "'")
	return {
		"unzip -o -q " .. quote(zipPath) .. " -d " .. quote(dir),
		"tar -xf " .. quote(zipPath) .. " -C " .. quote(dir),
		"python3 -c " .. python .. " " .. quote(zipPath) .. " " .. quote(dir)
	}
end

--- The command that starts the new executable without this process waiting for it: a shell
--- background job on POSIX, and the shell's own `start` on Windows.
---@param osName string
---@param executable string
---@return string
function install._relaunchCommand(osName, executable)
	if osName == "Windows" then return 'start "" ' .. quoteWindows(executable) end
	return quotePosix(executable) .. " >/dev/null 2>&1 &"
end

--- Whether a path names beat itself. A source run is the `lde` executable with beat's modules
--- linked in, so the name is what says whether there is a program here to replace.
---@param executable string?
---@return boolean
function install._isBeat(executable)
	if type(executable) ~= "string" then return false end
	local name = path.basename(executable):lower()
	if name:sub(-4) == ".exe" then name = name:sub(1, -5) end
	return name == "beat"
end

local selfPathCache
local selfPathRead = false

--- The executable this process runs from, or nil when it has none of its own. The answer is kept
--- because replacing the executable makes Linux's `/proc/self/exe` point at the old, deleted
--- inode; the place the program runs from is still the path it started at.
---@return string?
function install.selfPath()
	if selfPathRead then return selfPathCache end
	selfPathRead = true

	if platform.android then return nil end

	-- An AppImage runs from a read-only mount of itself; the file to replace, and to start again,
	-- is the AppImage, which its runtime names in APPIMAGE.
	local appImage = jit.os == "Linux" and os.getenv("APPIMAGE") or nil
	if appImage ~= nil and appImage ~= "" then
		selfPathCache = appImage
		return appImage
	end

	local ok, executable = pcall(env.execPath)
	if not ok or type(executable) ~= "string" or executable == "" then return nil end

	-- Linux appends this once the file the link names has been replaced. An update does exactly
	-- that, and a relaunch afterwards still has to name the executable's place.
	if jit.os == "Linux" then executable = executable:gsub("%s+%(deleted%)$", "") end
	if not install._isBeat(executable) then return nil end

	selfPathCache = executable
	return executable
end

---@param result any
local function succeeded(result)
	return result == true or result == 0
end

---@param command string
local function run(command)
	local ok, result = pcall(os.execute, command)
	return ok and succeeded(result)
end

--- The `beat` (or `beat.exe`) a release zip contains, under whatever folder it puts it in.
---@param dir string
---@param osName string
local function findExecutable(dir, osName)
	local wanted = osName == "Windows" and "beat.exe" or "beat"

	---@param current string
	---@return string?
	local function walk(current)
		local entries = fs.readdir(current)
		if entries == nil then return nil end
		while true do
			local entry = entries()
			if entry == nil then return nil end
			local full = path.join(current, entry.name)
			local kind = entry.type
			if kind == "unknown" then kind = fs.isdir(full) and "dir" or "file" end
			if kind == "dir" then
				local found = walk(full)
				if found ~= nil then return found end
			elseif entry.name:lower() == wanted then
				return full
			end
		end
	end

	return walk(dir)
end

---@param osName string
---@param executable string
local function removeQuarantine(osName, executable)
	if osName ~= "OSX" then return end
	run("xattr -d com.apple.quarantine " .. quotePosix(executable) .. " >/dev/null 2>&1")
end

--- Replaces the executable on a POSIX system. The new file is copied beside the old one first:
--- the config directory and the install can sit on different filesystems, where a rename from
--- the extraction folder would fail, and a plain copy would leave the file without its mode.
---@param executable string
---@param newExecutable string
---@return boolean
---@return string? err
local function replacePosix(executable, newExecutable)
	local staged = executable .. ".new"
	pcall(fs.delete, staged)

	if not fs.copyAtomic(newExecutable, staged) then
		return false, "could not copy the new executable beside the old one"
	end
	if not fs.chmod(staged, tonumber("755", 8)) then
		pcall(fs.delete, staged)
		return false, "could not make the new executable runnable"
	end

	local renamed, renameErr = os.rename(staged, executable)
	if not renamed then
		pcall(fs.delete, staged)
		return false, "could not replace the executable: " .. tostring(renameErr)
	end

	removeQuarantine(jit.os, executable)
	return true
end

--- Replaces the executable on Windows. A running image cannot be deleted or written over, but it
--- can be renamed: the old file goes aside, which frees the path for the new one. The old image is
--- left for the next update to remove, since this process still has it open until it leaves.
---@param executable string
---@param newExecutable string
---@return boolean
---@return string? err
local function replaceWindows(executable, newExecutable)
	local old = executable .. ".old"
	-- Whatever a previous update left there is not running any more, so it can go.
	pcall(fs.delete, old)

	local aside, asideErr = fs.move(executable, old)
	if not aside then
		return false, "could not move the old executable aside: " .. tostring(asideErr)
	end

	local placed, placeErr = fs.move(newExecutable, executable)
	if not placed then
		-- Put the old image back rather than leave the install without a program at all.
		pcall(fs.move, old, executable)
		return false, "could not put the new executable in place: " .. tostring(placeErr)
	end

	return true
end

---@param executable string
---@param zipPath string
---@param dir string
---@return boolean
---@return string? err
local function applyArchive(executable, zipPath, dir)
	local unpacked = false
	for _, command in ipairs(install._commands(jit.os, zipPath, dir)) do
		if run(command) then
			unpacked = true
			break
		end
	end
	if not unpacked then return false, "the update archive could not be unpacked" end

	local newExecutable = findExecutable(dir, jit.os)
	if newExecutable == nil then return false, "the update archive has no beat executable" end

	if jit.os == "Windows" then return replaceWindows(executable, newExecutable) end
	return replacePosix(executable, newExecutable)
end

--- Downloads a release zip and puts its executable in place. The callbacks are the only way this
--- speaks: progress while the transfer runs, and one answer when it is done. Nothing here raises;
--- a failed update leaves the old executable where it was.
---@param app beat.App
---@param asset { url: string, name: string? }
---@param callbacks { onProgress: (fun(fraction: number|nil))?, onDone: fun(ok: boolean, err: string?) }
function install.apply(app, asset, callbacks)
	callbacks = callbacks or {}

	local finished = false
	---@param ok boolean
	---@param err string?
	local function finish(ok, err)
		if finished then return end
		finished = true
		if type(callbacks.onDone) == "function" then pcall(callbacks.onDone, ok, err) end
	end

	if platform.android then return finish(false, "updates on Android are installed by the system") end

	local executable = install.selfPath()
	if executable == nil then return finish(false, "beat is not running from its own executable") end
	if type(asset) ~= "table" or type(asset.url) ~= "string" or asset.url == "" then
		return finish(false, "the update has no download")
	end

	local http = app ~= nil and app.services ~= nil and app.services.http or nil
	if http == nil then return finish(false, "the app has no http service") end

	local dir = path.join(paths.directory(), "update")
	pcall(fs.rmdir, dir)
	pcall(fs.mkdirAll, dir)
	local name = type(asset.name) == "string" and path.basename(asset.name) or ""
	if name == "" or name == "." or name == ".." then name = "beat.zip" end
	local archive = path.join(dir, name)

	local requested, requestErr = pcall(http.download, http, {
		url = asset.url,
		path = archive,
		onProgress = function(received, total)
			if type(callbacks.onProgress) ~= "function" then return end
			-- libcurl has no total until the response headers arrive, and an unknown progress is
			-- what the task list draws as indeterminate.
			local fraction
			if type(received) == "number" and type(total) == "number" and total > 0 then
				fraction = math.max(0, math.min(1, received / total))
			end
			pcall(callbacks.onProgress, fraction)
		end,
		onDone = function(downloaded, downloadErr)
			if not downloaded then
				pcall(fs.rmdir, dir)
				return finish(false, downloadErr or "the update could not be downloaded")
			end

			-- An AppImage update is the new AppImage itself, put in place as it is; anything else is
			-- an archive the executable is taken out of.
			local called, applied, applyErr
			if name:match("%.AppImage$") then
				called, applied, applyErr = pcall(replacePosix, executable, archive)
			else
				called, applied, applyErr = pcall(applyArchive, executable, archive, dir)
			end
			-- The archive's bytes are spent once the executable has been taken out of it.
			pcall(fs.rmdir, dir)
			if called then
				finish(applied, applyErr)
			else
				finish(false, tostring(applied))
			end
		end
	})

	if not requested then
		pcall(fs.rmdir, dir)
		finish(false, tostring(requestErr))
	end
end

--- Starts a fresh copy of the executable without waiting for it. The process package is what a
--- worker launch already uses; it is required here rather than at the top so its declaration of
--- `struct pollfd` cannot reach a window that loaded winit's own first. The shell is the fallback
--- for a machine where spawning fails.
---@param executable string
---@return boolean
---@return string? err
local function startDetached(executable)
	local lastErr
	local ok, module = pcall(require, "process")
	if ok and module ~= nil then
		---@cast module process
		local child, spawnErr = module.spawn(executable, {}, { stdout = "null", stderr = "null" })
		if child ~= nil then return true end
		lastErr = spawnErr
	end

	if run(install._relaunchCommand(jit.os, executable)) then return true end
	return false, lastErr or "the executable could not be started"
end

--- Starts the updated executable and leaves this copy. The single-instance claim is released
--- first: a new copy that found it held would ask this one to come forward and end itself, which
--- after a replacement is a hand-over to a process that is already on its way out. That is also
--- why the release comes before the new process starts rather than a delay after it.
---@param app beat.App
---@return boolean started
function install.relaunch(app)
	local executable = install.selfPath()
	if executable == nil then
		Log.write("error", "cannot relaunch beat: it is not running from its own executable")
		error("beat is not running from its own executable", 0)
	end

	if app ~= nil and app.instance ~= nil then
		pcall(function() app.instance:release() end)
		app.instance = nil
	end

	-- What the app remembers is written before the new copy can read it. `App:leave` does this
	-- too, but only after the new process has had time to start and load the same files.
	if app ~= nil and app.flush ~= nil then pcall(app.flush, app) end

	local started, err = startDetached(executable)
	if not started then
		local message = "could not start the updated beat: " .. tostring(err)
		Log.write("error", message)
		-- The claim went first so the new copy could take it. Nothing took it, so this copy takes
		-- it back and keeps running rather than leaving the person with nothing on the screen.
		if app ~= nil then app.instance = instance.claim(paths.directory()) end
		error(message, 0)
	end

	if app ~= nil then app:leave() end
	return true
end

return install
