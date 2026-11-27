local test = require("lde-test")
local fs = require("fs")
local picker = require("beat.app.services.scan.picker")

local function resultFile(value)
	local file = os.tmpname() .. "-beat-picker-test"
	assert(fs.write(file, value))
	return { file = file, platform = "test" }
end

test.it("reads a chosen folder and removes the result", function()
	local directory = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
	local handle = resultFile(directory .. "\n")
	local path, status = picker.poll(handle)

	test.equal(path, directory)
	test.falsy(status)
	test.falsy(fs.isfile(handle.file))
end)

test.it("distinguishes cancellation from a missing dialog", function()
	local cancelled, cancelStatus = picker.poll(resultFile("__CANCEL__"))
	test.falsy(cancelled)
	test.equal(cancelStatus, "cancelled")

	local missing, missingStatus = picker.poll(resultFile("__NO_PICKER__"))
	test.falsy(missing)
	test.equal(missingStatus, "no-picker")
end)

test.it("does nothing while the dialog has not written a result", function()
	local file = os.tmpname() .. "-beat-picker-empty"
	assert(fs.write(file, ""))
	local path, status = picker.poll({ file = file, platform = "test" })
	test.falsy(path)
	test.falsy(status)
	fs.delete(file)
end)

test.it("reads a chosen file and tells it from a folder", function()
	local file = os.tmpname() .. "-beat-picker-file.txt"
	assert(fs.write(file, "profile"))
	local handle = resultFile(file .. "\n")
	handle.kind = "file"
	local path, status = picker.poll(handle)
	test.equal(path, file)
	test.falsy(status)
	fs.delete(file)
end)

test.it("a file pick refuses a folder answer", function()
	local directory = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
	local handle = resultFile(directory .. "\n")
	handle.kind = "file"
	local path, status = picker.poll(handle)
	test.falsy(path)
	test.equal(status, "cancelled")
end)
