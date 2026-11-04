local test = require("lde-test")
local fs = require("fs")
local picker = require("beat.app.picker")

local function resultFile(value)
	local file = os.tmpname() .. "-beat-picker-test"
	assert(fs.write(file, value))
	return { file = file, platform = "test" }
end

test.it("reads a chosen folder and removes the result", function()
	local handle = resultFile("/tmp\n")
	local path, status = picker.poll(handle)

	test.equal(path, "/tmp")
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
