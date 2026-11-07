local test = require("lde-test")
local folders = require("beat.app.folders")

-- The Windows rules are plain string work, so they are checked on every platform.
local function asWindows(fn)
	local windows = folders.windows
	folders.windows = true
	local ok, err = pcall(fn)
	folders.windows = windows
	assert(ok, err)
end

test.it("keeps a Windows drive root as the root, not the drive's current directory", function()
	asWindows(function()
		test.equal(folders.normalize("C:\\", "D:\\Music", "C:\\Users\\me"), "C:\\")
		test.equal(folders.normalize("d:", "C:\\Music", "C:\\Users\\me"), "D:\\", "a bare drive is its root")
		test.equal(folders.normalize("E:/Music/./Albums/../Singles", "C:\\", "C:\\Users\\me"), "E:\\Music\\Singles")
		test.equal(folders.normalize("C:\\..\\..", "C:\\", "C:\\Users\\me"), "C:\\", "nothing climbs past a root")
	end)
end)

test.it("reads a typed Windows path the way Explorer hands it out", function()
	asWindows(function()
		test.equal(folders.normalize('  "D:\\My Music"  ', "C:\\", "C:\\Users\\me"), "D:\\My Music")
		test.equal(folders.normalize("~\\Music", "D:\\", "C:\\Users\\me"), "C:\\Users\\me\\Music")
		test.equal(folders.normalize("Albums", "D:\\Music", "C:\\Users\\me"), "D:\\Music\\Albums",
			"a relative path is inside the folder shown")
		test.equal(folders.normalize("\\Albums", "D:\\Music", "C:\\Users\\me"), "D:\\Albums",
			"a leading backslash is the current drive's root")
		test.equal(folders.normalize("\\\\nas\\media\\Music", "C:\\", "C:\\Users\\me"), "\\\\nas\\media\\Music")
	end)
end)

test.it("stops going up at a Windows root", function()
	asWindows(function()
		test.equal(folders.parent("C:\\Users\\me"), "C:\\Users")
		test.equal(folders.parent("C:\\Users"), "C:\\")
		test.equal(folders.parent("C:\\"), nil, "above a drive is the list of drives")
		test.equal(folders.parent("\\\\nas\\media\\Music"), "\\\\nas\\media\\")
		test.equal(folders.parent("\\\\nas\\media\\"), nil)
		test.equal(folders.join("C:\\", "Users"), "C:\\Users")
		test.equal(folders.join("C:\\Users", "me"), "C:\\Users\\me")
	end)
end)

-- The POSIX side leans on the `path` library, which reads paths the host's way.
test.skipIf(jit.os == "Windows")("walks POSIX paths up to /", function()
	test.equal(folders.normalize("Music", "/home/me", "/home/me"), "/home/me/Music")
	test.equal(folders.normalize("~/Music/", "/", "/home/me"), "/home/me/Music")
	test.equal(folders.parent("/home"), "/")
	test.equal(folders.parent("/"), nil)
	test.equal(folders.join("/", "home"), "/home")
end)
