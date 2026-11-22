-- What the device beat runs on says about the screen and the filesystem: an Android phone draws at
-- its display density and under its system bars, and keeps music in the shared Music folder. On a
-- desktop every answer is the neutral one.
local platform = {}

--- Whether this process is an Android app: the APK's bootstrap hands Lua the native activity.
platform.android = rawget(_G, "LDE_ANDROID_APP") ~= nil

---@class beat.platform.Screen
---@field density number # Physical pixels per density-independent pixel (1 on a desktop)
---@field top number # Physical pixels the status bar and camera cutout cover at the top
---@field bottom number # Physical pixels the navigation bar covers at the bottom

---@type beat.platform.Screen?
local screen

local NEUTRAL = { density = 1, top = 0, bottom = 0 }

---@return beat.platform.Screen
local function readAndroidScreen()
	local android = require("androidapi")
	local jni = android.jni
	local activity = assert(android.activity()).clazz

	local values, err = jni.frame(function()
		local resources = jni.call(activity, "android/content/Context", "getResources", "()Landroid/content/res/Resources;", "object")
		local metrics = jni.call(resources, "android/content/res/Resources", "getDisplayMetrics", "()Landroid/util/DisplayMetrics;", "object")
		local density = jni.floatField(metrics, "android/util/DisplayMetrics", "density")

		---@param name string
		local function dimension(name)
			local id = jni.call(resources, "android/content/res/Resources", "getIdentifier", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)I", "int", jni.string(name), jni.string("dimen"), jni.string("android"))
			if id == 0 then return 0 end
			return tonumber(jni.call(resources, "android/content/res/Resources", "getDimensionPixelSize", "(I)I", "int", id)) or 0
		end

		return { density = density, top = dimension("status_bar_height"), bottom = dimension("navigation_bar_height") }
	end)

	if values == nil then
		require("beat.log").write("warn", "could not read the screen's density: " .. tostring(err))
		return NEUTRAL
	end
	return values --[[@as beat.platform.Screen]]
end

--- The screen's density and the bars drawn over it, read once.
---@return beat.platform.Screen
function platform.screen()
	if screen == nil then
		screen = platform.android and readAndroidScreen() or NEUTRAL
	end
	return screen
end

--- The music folder a first launch uses without asking, where the platform has one.
---@return string?
function platform.defaultMusicFolder()
	if platform.android then return "/storage/emulated/0/Music" end
	return nil
end

-- Android 13 and later name audio files their own permission; before that one permission covers all
-- of shared storage.
local AUDIO_PERMISSION_33 = "android.permission.READ_MEDIA_AUDIO"
local AUDIO_PERMISSION_OLD = "android.permission.READ_EXTERNAL_STORAGE"
local PERMISSION_GRANTED = 0

-- JNIEnv slots androidapi has no wrapper for: `requestPermissions` takes a `String[]`.
local NEW_OBJECT_ARRAY = 172
local SET_OBJECT_ARRAY_ELEMENT = 174

---@return string
local function audioPermission()
	local android = require("androidapi")
	return assert(android.activity()).sdkVersion >= 33 and AUDIO_PERMISSION_33 or AUDIO_PERMISSION_OLD
end

--- Whether the app may read the music folder. Always true off Android.
---@return boolean
function platform.canReadMusic()
	if not platform.android then return true end
	local android = require("androidapi")
	local jni = android.jni
	local activity = assert(android.activity()).clazz
	local granted = jni.frame(
		|| -> jni.call(
			activity,
			"android/content/Context",
			"checkSelfPermission",
			"(Ljava/lang/String;)I",
			"int",
			jni.string(audioPermission())
		)
	)
	return granted == PERMISSION_GRANTED
end

-- AudioManager.STREAM_MUSIC: what music is played on, rather than the ringtone the hardware keys
-- change by default when nothing is playing.
local STREAM_MUSIC = 3

--- Points the hardware volume keys at the stream beat plays on. Left alone, a phone changes its
--- ringer volume whenever the keys are pressed and nothing is playing, which is most of a music
--- player's life; the activity's choice stays for as long as it is in front, so this is asked for
--- once at launch. Does nothing off Android.
function platform.useMediaVolumeKeys()
	if not platform.android then return end
	local android = require("androidapi")
	local jni = android.jni
	local activity = assert(android.activity()).clazz

	local _, err = jni.frame(
		|| -> jni.call(activity, "android/app/Activity", "setVolumeControlStream", "(I)V", "void", STREAM_MUSIC)
	)
	if err ~= nil then
		require("beat.log").write("warn", "could not point the volume keys at media: " .. tostring(err))
	end
end

--- Shows the system's prompt for reading audio files. The answer is not reported back to a
--- NativeActivity; `canReadMusic` says what it was once the app is resumed.
function platform.requestMusicAccess()
	if not platform.android then return end
	local ffi = require("ffi")
	local android = require("androidapi")
	local jni = android.jni
	local activity = assert(android.activity()).clazz
	local _, err = jni.frame(function()
		local env = ffi.cast("struct androidapi_jni_env*", jni.env())
		local newArray = ffi.cast("void*(*)(void*, int32_t, void*, void*)", env.functions[NEW_OBJECT_ARRAY])
		local setElement = ffi.cast("void(*)(void*, void*, int32_t, void*)", env.functions[SET_OBJECT_ARRAY_ELEMENT])
		local name = jni.string(audioPermission())
		local names = newArray(env, 1, jni.class("java/lang/String"), nil)
		setElement(env, names, 0, name)
		jni.call(activity, "android/app/Activity", "requestPermissions", "([Ljava/lang/String;I)V", "void", names, 1)
	end)
	if err ~= nil then require("beat.log").write("warn", "could not ask for music access: " .. tostring(err)) end
end

return platform
