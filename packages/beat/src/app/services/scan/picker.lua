-- A native folder dialog, through winit. The call is modal: the window waits in the system's own
-- chooser and the chosen path is written into a file the ticker polls, so the rest of the app has
-- one place to read a result whether the dialog was shown on Windows, macOS or Linux.
local fs = require("fs")
local jit = require("jit")
local winit = require("winit")

local picker = {}

---@class beat.FolderPick
---@field file string
---@field platform string
---@field kind "folder"|"file"? # What the dialog asks for; a handle without one is a folder pick

--- Starts the dialog. A file is returned even when no native picker exists; `poll` says which.
---@param window winit.Window?
---@param opts { title: string? }?
---@return beat.FolderPick
function picker.start(window, opts)
	local file = os.tmpname() .. "-beat-folder"
	local osName = jit.os or ""
	local dialog = winit.FileDialog

	fs.delete(file)

	if dialog == nil then
		fs.write(file, "__NO_PICKER__")
		return { file = file, platform = osName }
	end

	local pickFolder = dialog.pickFolder
	if pickFolder == nil then
		fs.write(file, "__NO_PICKER__")
		return { file = file, platform = osName }
	end
	local title = opts ~= nil and opts.title or "Choose music folder"
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
	local ok, path = pcall(pickFile, window, { title = title, filters = opts ~= nil and opts.filters or nil })
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
	if pick == nil or not fs.isfile(pick.file) then return nil end

	local value = fs.read(pick.file)
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

--- Drops a dialog that is no longer wanted. The modal dialog has already returned by the time the
--- app can cancel it; what is left is the answer file nobody will poll.
---@param pick beat.FolderPick?
function picker.cancel(pick)
	if pick ~= nil then fs.delete(pick.file) end
end

return picker
