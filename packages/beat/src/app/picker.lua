-- A native folder dialog, in a process of its own.
--
-- The dialog is a window the desktop owns rather than a screen wonderland draws: zenity or kdialog
-- on Linux, the Finder's chooser on macOS. The command writes one line into a temporary file and
-- the app polls that file from its ticker, so the window stays responsive while the chooser is up.
-- Where neither dialog exists the result says so and the app can open its own folder browser.
local fs = require("fs")
local jit = require("jit")

local picker = {}

---@class beat.FolderPick
---@field file string
---@field platform string

---@param value string
---@return string
local function quote(value)
	return "'" .. value:gsub("'", "'\\''") .. "'"
end

---@return string
local function linuxCommand(file)
	local target = quote(file)
	return "{ "
	.. "if command -v zenity >/dev/null 2>&1; then "
	.. "p=$(zenity --file-selection --directory --title='Choose music folder' 2>/dev/null); "
	.. "if [ -n \"$p\" ]; then printf '%s' \"$p\"; else printf '__CANCEL__'; fi; "
	.. "elif command -v kdialog >/dev/null 2>&1; then "
	.. "p=$(kdialog --getexistingdirectory \"$HOME\" --title 'Choose music folder' 2>/dev/null); "
	.. "if [ -n \"$p\" ]; then printf '%s' \"$p\"; else printf '__CANCEL__'; fi; "
	.. "else printf '__NO_PICKER__'; fi; } > " .. target .. " 2>/dev/null &"
end

---@return string
local function macCommand(file)
	local target = quote(file)
	return "{ p=$(osascript -e 'POSIX path of (choose folder with prompt \"Choose music folder\")' "
	.. "2>/dev/null); if [ -n \"$p\" ]; then printf '%s' \"$p\"; else printf '__CANCEL__'; fi; } > "
	.. target .. " 2>/dev/null &"
end

--- Starts the dialog. A file is returned even when no native picker exists; `poll` says which.
---@return beat.FolderPick
function picker.start()
	local file = os.tmpname() .. "-beat-folder"
	fs.delete(file)

	local osName = jit.os or ""
	local command
	if osName == "Linux" then
		command = linuxCommand(file)
	elseif osName == "OSX" then
		command = macCommand(file)
	else
		-- Windows has no portable shell dialog here; leave it to the in-app browser.
		assert(fs.write(file, "__NO_PICKER__"))
		return { file = file, platform = osName}
	end

	os.execute(command)
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

--- Drops a dialog that is no longer wanted. The child keeps running until it is closed; what it
--- writes to a file nobody reads is harmless.
---@param pick beat.FolderPick?
function picker.cancel(pick)
	if pick ~= nil then fs.delete(pick.file) end
end

return picker
