-- Opening a URL in whatever browser the desktop uses, or a folder in its file manager. The
-- commands are the same ones the Last.fm authorization page uses; only http(s) is accepted so a
-- message cannot reach a shell otherwise.
local fs = require("fs")

local links = {}

local isAndroid = rawget(_G, "LDE_ANDROID_APP") ~= nil

---@class beat.LinksJni
---@field frame fun(body: fun(): any): any
---@field new fun(className: string, signature: string, ...: any): any
---@field call fun(object: any, className: string, name: string, signature: string, ret: string, ...: any): any
---@field callStatic fun(className: string, name: string, signature: string, ...: any): any
---@field string fun(value: string): any

---@class beat.LinksAndroidApi
---@field isAndroid boolean
---@field jni beat.LinksJni
---@field activity fun(): { clazz: any }?

--- Ask Android to show a URL in whatever activity handles it: the browser, or the app that
--- registered the scheme. The activity is the app's, so the intent needs no new task of its own.
---@param url string
local function openAndroid(url)
	local ok, android = pcall(require, "androidapi")
	if not ok then return false end
	---@cast android beat.LinksAndroidApi
	if not android.isAndroid then return false end

	local jni = android.jni
	local activity = android.activity()
	if activity == nil then return false end

	local started = jni.frame(function()
		local intent = jni.new("android/content/Intent", "(Ljava/lang/String;)V",
			jni.string("android.intent.action.VIEW"))
		local uri = jni.callStatic("android/net/Uri", "parse", "(Ljava/lang/String;)Landroid/net/Uri;", jni.string(url))
		if uri == nil then return false end
		jni.call(intent, "android/content/Intent", "setData", "(Landroid/net/Uri;)Landroid/content/Intent;", "object", uri)
		jni.call(activity.clazz, "android/app/Activity", "startActivity", "(Landroid/content/Intent;)V", "void", intent)
		return true
	end)

	return started == true
end

---@param value string
local function quote(value)
	if jit.os == "Windows" then return '"' .. value:gsub('"', '\\"') .. '"' end
	return "'" .. value:gsub("'", "'\\''") .. "'"
end

---@param url string
---@return boolean
function links.open(url)
	if type(url) ~= "string" or not url:match("^https?://") then return false end

	if isAndroid then return openAndroid(url) end

	local target = quote(url)
	local osName = jit.os or ""

	if osName == "Windows" then
		return os.execute('start "" ' .. target) ~= nil
	elseif osName == "OSX" then
		return os.execute("open " .. target .. " >/dev/null 2>&1 &") == 0
	end

	return os.execute(
		"(xdg-open " .. target .. " >/dev/null 2>&1 || gio open " .. target .. " >/dev/null 2>&1 || sensible-browser " .. target .. " >/dev/null 2>&1) &"
	) == 0
end

--- Opens a directory in the desktop's file manager. Only a path is accepted, never an arbitrary
--- command, and it must point at a directory so a typo cannot launch something else.
---@param dir string
---@return boolean
function links.openFolder(dir)
	if type(dir) ~= "string" or not fs.isdir(dir) then return false end

	local target = quote(dir)
	local osName = jit.os or ""

	if osName == "Windows" then
		return os.execute("explorer " .. target) ~= nil
	elseif osName == "OSX" then
		return os.execute("open " .. target .. " >/dev/null 2>&1 &") == 0
	end

	return os.execute("(xdg-open " .. target .. " >/dev/null 2>&1 || gio open " .. target .. " >/dev/null 2>&1) &") == 0
end

return links
