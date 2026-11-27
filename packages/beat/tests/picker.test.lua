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

test.it("reads an answer a worker wrote and joins it", function()
	local directory = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
	local file = os.tmpname() .. "-beat-picker-worker"
	local threading = require("threading")
	local thread = threading.spawn(function()
		local workerFs = require("fs")
		workerFs.write(file .. ".part", directory .. "\n")
		workerFs.move(file .. ".part", file)
	end)
	local handle = { file = file, platform = "test", thread = thread }

	local path, status
	local time = require("wonderland.time")
	local deadline = time.now() + 5
	while time.now() < deadline do
		path, status = picker.poll(handle)
		if path ~= nil or status ~= nil then break end
		threading.sleep(1)
	end

	test.equal(path, directory)
	test.falsy(status)
	test.falsy(handle.thread, "the poll joined the worker")
	test.falsy(fs.isfile(file))
end)

test.it("answers no-picker when a worker ends without writing", function()
	local file = os.tmpname() .. "-beat-picker-empty-worker"
	fs.delete(file)
	local handle = {
		file = file,
		platform = "test",
		thread = {
			done = function() return true end,
			join = function() end
		}
	}

	local path, status = picker.poll(handle)
	test.falsy(path)
	test.equal(status, "no-picker")
	test.falsy(handle.thread, "the poll joined the worker")
end)

test.it("asks for a folder answer four times a second while the dialog is open", function()
	local Scan = require("beat.app.services.scan")
	local scan = Scan.new({
		settings = { values = {} },
		library = {},
		covers = {},
		playback = {},
		toasts = { show = function() end },
		emit = function() end,
		window = function() return nil end,
		options = {}
	})
	scan.pick = { file = os.tmpname() .. "-beat-picker-pending", platform = "test" }

	local changed, busy = scan:step(0)
	test.falsy(changed)
	test.equal(busy, 0.25, "the open dialog is polled, not drawn for")
end)
