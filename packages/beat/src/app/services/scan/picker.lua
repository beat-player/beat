-- A native folder dialog, through winit. On the desktops whose chooser is a blocking call the
-- window waits in the system's own dialog, and the chosen path is written into a file the ticker
-- polls, so the rest of the app has one place to read a result whether the dialog was shown on
-- Windows, macOS or Linux.
--
-- On Linux the waiting is done on a thread of its own: the portal speaks D-Bus and a chooser
-- program waits on a pipe, and either would hold the window still -- no drawing, no playhead, no
-- spectrum -- for as long as the dialog is open. The worker writes the answer where `poll` reads
-- it, so the app side is the same file protocol on every platform.
local fs = require("fs")
local jit = require("jit")
local threading = require("threading")
local platform = require("beat.platform")
local winit = require("winit")

local picker = {}

---@class beat.FolderPick
---@field file string
---@field platform string
---@field kind "folder"|"file"? # What the dialog asks for; a handle without one is a folder pick
---@field thread threading.Handle? # The Linux worker showing the dialog, until its answer is read

--- Whether the dialog should run away from the frame loop: only a desktop Linux build has the
--- portal and chooser programs, and a phone's file dialog is the system's own activity.
---@return boolean
local function inWorker()
	return jit.os == "Linux" and not platform.android
end

--- The parent the portal dialog is shown over. Only the window's id crosses to the thread: a
--- cdata or a table is not something `threading` can copy, so anything that is not a number is
--- left out and the dialog stands on its own.
---@param window winit.Window?
---@return number?
local function parentId(window)
	if window == nil or window.id == nil then return nil end
	local ok, id = pcall(tonumber, window.id)
	return ok and id or nil
end

--- The job a worker runs. It is made here, before spawning, with only copyable upvalues -- a file,
--- a title, a kind, the parent's window id and plain filters -- so `threading` can carry it into
--- its own state, where the dialog modules are loaded without the window or its display.
---@param file string
---@param title string
---@param kind "folder"|"file"
---@param windowId number?
---@param filters winit.FileFilter[]?
---@return fun()
local function dialogJob(file, title, kind, windowId, filters)
	return function()
		local workerFs = require("fs")
		local function answer(value)
			local part = file .. ".part"
			if workerFs.write(part, value) then workerFs.move(part, file) end
		end

		local loaded, winitModule = pcall(require, "winit")
		local dialog = loaded and winitModule.FileDialog or nil
		local pick = dialog ~= nil and (kind == "file" and dialog.pickFile or dialog.pickFolder) or nil
		if pick == nil then
			answer("__NO_PICKER__")
			return
		end

		local parent = windowId ~= nil and { id = windowId } or nil
		local called, path = pcall(pick, parent, { title = title, filters = filters })
		if not called or type(path) ~= "string" then
			answer("__NO_PICKER__")
		elseif path == "" then
			answer("__CANCEL__")
		else
			answer(path)
		end
	end
end

--- Starts the dialog. A file is returned even when no native picker exists; `poll` says which.
---@param window winit.Window?
---@param opts { title: string? }?
---@return beat.FolderPick
function picker.start(window, opts)
	local file = os.tmpname() .. "-beat-folder"
	local osName = jit.os or ""
	local dialog = winit.FileDialog

	fs.delete(file)

	local pickFolder = dialog ~= nil and dialog.pickFolder or nil
	if pickFolder == nil then
		fs.write(file, "__NO_PICKER__")
		return { file = file, platform = osName }
	end

	local title = opts ~= nil and opts.title or "Choose music folder"
	if inWorker() then
		local windowId = parentId(window)
		local ok, thread = pcall(threading.spawn, dialogJob(file, title, "folder", windowId, nil))
		if ok then return { file = file, platform = osName, thread = thread } end
		-- A thread that cannot start is a dialog that is still better than none.
	end

	local ok, path = pcall(pickFolder, window, { title = title })

	if not ok or type(path) ~= "string" then
		fs.write(file, "__NO_PICKER__")
	elseif path == "" then
		fs.write(file, "__CANCEL__")
	else
		fs.write(file, path)
	end

	return { file = file, platform = osName }
end

--- The same dialog asking for one file. A build whose platform names no file chooser answers
--- `no-picker` rather than pretending to have asked, which is what hides the choice on a phone.
---@param window winit.Window?
---@param opts { title: string?, filters: winit.FileFilter[]? }?
---@return beat.FolderPick
function picker.startFile(window, opts)
	local file = os.tmpname() .. "-beat-file"
	local osName = jit.os or ""
	local dialog = winit.FileDialog

	fs.delete(file)

	local pickFile = dialog ~= nil and dialog.pickFile or nil
	if pickFile == nil then
		fs.write(file, "__NO_PICKER__")
		return { file = file, platform = osName, kind = "file" }
	end

	local title = opts ~= nil and opts.title or "Choose profile"
	local filters = opts ~= nil and opts.filters or nil
	if inWorker() then
		local windowId = parentId(window)
		local ok, thread = pcall(threading.spawn, dialogJob(file, title, "file", windowId, filters))
		if ok then return { file = file, platform = osName, kind = "file", thread = thread } end
	end

	local ok, path = pcall(pickFile, window, { title = title, filters = filters })
	if not ok or type(path) ~= "string" then
		fs.write(file, "__NO_PICKER__")
	elseif path == "" then
		fs.write(file, "__CANCEL__")
	else
		fs.write(file, path)
	end

	return { file = file, platform = osName, kind = "file" }
end

--- The chosen path, or a status when the dialog was cancelled or is not available.
---@param pick beat.FolderPick
---@return string? path
---@return string? status # "cancelled", "no-picker", or nil while the dialog is still open
function picker.poll(pick)
	if pick == nil then return nil end

	if fs.isfile(pick.file) then
		local value = fs.read(pick.file)
		local thread = pick.thread
		if thread ~= nil then
			-- The worker writes its answer just before it returns, so this join is immediate; it
			-- is what gives the thread's state back rather than leaving it for the process.
			pick.thread = nil
			pcall(thread.join, thread)
		end
		if value == nil or value == "" then return nil end

		fs.delete(pick.file)
		value = value:gsub("[\r\n]+$", "")
		if value == "__NO_PICKER__" then return nil, "no-picker" end
		if value == "__CANCEL__" then return nil, "cancelled" end
		if pick.kind == "file" then
			if value ~= "" and fs.isfile(value) then return value end
		elseif value ~= "" and fs.isdir(value) then
			return value
		end
		return nil, "cancelled"
	end

	local thread = pick.thread
	if thread ~= nil and thread:done() then
		-- A worker that ended without writing an answer could not load the dialog or reach the
		-- portal; the thread's error is its own, and the app reads the same status as a build
		-- with no chooser.
		pick.thread = nil
		pcall(thread.join, thread)
		return nil, "no-picker"
	end

	return nil
end

--- Drops a dialog that is no longer wanted. A worker already in the chooser cannot be called
--- back out of it -- the answer is written where nobody polls now -- and a synchronous call has
--- already returned by the time the app can cancel it. What is left is the answer file.
---@param pick beat.FolderPick?
function picker.cancel(pick)
	if pick ~= nil then
		fs.delete(pick.file)
		local part = pick.file .. ".part"
		fs.delete(part)
	end
end

return picker
