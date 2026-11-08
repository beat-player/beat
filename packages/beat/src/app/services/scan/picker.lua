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
		return { file = file, platform = osName}
	end

	local title = opts ~= nil and opts.title or "Choose music folder"
	local ok, path = pcall(dialog.pickFolder, window, { title = title })

	if not ok then
		fs.write(file, "__NO_PICKER__")
	elseif path == nil or path == "" then
		fs.write(file, "__CANCEL__")
	else
		fs.write(file, path)
	end

	return { file = file, platform = osName}
end

--- The chosen folder, or a status when the dialog was cancelled or is not available.
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
	if value ~= "" and fs.isdir(value) then return value end
	return nil, "cancelled"
end

--- Drops a dialog that is no longer wanted. The modal dialog has already returned by the time the
--- app can cancel it; what is left is the answer file nobody will poll.
---@param pick beat.FolderPick?
function picker.cancel(pick)
	if pick ~= nil then fs.delete(pick.file) end
end

return picker
