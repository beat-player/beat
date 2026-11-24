-- What the installer builds before it runs anything: the commands that unpack a release zip and
-- start the new executable again, and how it tells beat's own binary from the `lde` runtime a
-- source run uses. The paths go through a shell, so quoting is the part worth pinning down.
local test = require("lde-test")
local install = require("beat.app.services.update.install")

test.it("recognises beat's executable by name, with or without an extension", function()
	test.truthy(install._isBeat("beat"))
	test.truthy(install._isBeat("/usr/local/bin/beat"))
	test.truthy(install._isBeat("/home/me/.local/bin/beat"))
	test.truthy(install._isBeat("C:\\Program Files\\beat\\beat.exe"))
	test.truthy(install._isBeat("C:\\Program Files\\beat\\BEAT.EXE"))
end)

test.it("does not mistake another program for beat", function()
	test.falsy(install._isBeat("/home/me/.cache/lde/bin/lde"))
	test.falsy(install._isBeat("/home/me/beat/beat-helper"))
	test.falsy(install._isBeat("/home/me/beat/beat.exe.old"))
	test.falsy(install._isBeat("notbeat"))
	test.falsy(install._isBeat(""))
	test.falsy(install._isBeat(nil))
end)

test.it("quotes paths with spaces in every way a zip is unpacked", function()
	local commands = install._commands("Linux", "/tmp/a b/beat.zip", "/tmp/a b/out")

	test.equal(#commands, 3)
	test.equal(commands[1], "unzip -o -q '/tmp/a b/beat.zip' -d '/tmp/a b/out'")
	test.equal(commands[2], "tar -xf '/tmp/a b/beat.zip' -C '/tmp/a b/out'")
	test.equal(
		commands[3],
		"python3 -c 'import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' '/tmp/a b/beat.zip' '/tmp/a b/out'"
	)
end)

test.it("quotes a Windows path with spaces for cmd.exe", function()
	local commands = install._commands("Windows", "C:\\Users\\A B\\beat.zip", "C:\\Users\\A B\\out")

	test.equal(commands[1], 'unzip -o -q "C:\\Users\\A B\\beat.zip" -d "C:\\Users\\A B\\out"')
	test.equal(commands[2], 'tar -xf "C:\\Users\\A B\\beat.zip" -C "C:\\Users\\A B\\out"')
	test.equal(
		commands[3],
		'python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "C:\\Users\\A B\\beat.zip" "C:\\Users\\A B\\out"'
	)
end)

test.it("escapes a single quote in a POSIX path", function()
	local commands = install._commands("Linux", "/tmp/it's/beat.zip", "/tmp/out")
	test.includes(commands[1], "'/tmp/it'\\''s/beat.zip'")
end)

test.it("starts the new copy in the background on POSIX and through start on Windows", function()
	test.equal(install._relaunchCommand("Linux", "/opt/beat dir/beat"), "'/opt/beat dir/beat' >/dev/null 2>&1 &")
	test.equal(install._relaunchCommand("OSX", "/Applications/beat"), "'/Applications/beat' >/dev/null 2>&1 &")
	test.equal(
		install._relaunchCommand("Windows", "C:\\Program Files\\beat\\beat.exe"),
		'start "" "C:\\Program Files\\beat\\beat.exe"'
	)
end)
