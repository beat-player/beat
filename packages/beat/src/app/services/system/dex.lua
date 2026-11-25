-- The Java classes beat's Android build ships as media.dex, and the loader they are found through.
-- An APK built with beat's `android.dex` carries the classes itself, together with the playback
-- service Android starts from them, and the activity's own loader finds them. An APK built without
-- one does not: the dex embedded in the app is written where only this app can reach it and loaded
-- at run time instead, which gives the lock-screen controls but no foreground service. Android 14
-- refuses to load a dex that can still be written, so the file is made read-only first; one left by
-- the last launch is replaced.
local dex = {}

--- The parts of androidapi's JNI wrapper these modules use.
---@class beat.DexJni
---@field frame fun(body: fun(): any, capacity: number?): any
---@field call fun(object: any, className: string, name: string, signature: string, ret: string, ...: any): any
---@field callStatic fun(className: string, name: string, signature: string, ...: any): any
---@field new fun(className: string, signature: string, ...: any): any
---@field string fun(value: string): any
---@field tostring fun(value: any): string
---@field global fun(value: any): any

---@class beat.NativeActivity
---@field clazz any

--- What `require("androidapi")` gives on a phone.
---@class beat.AndroidApi
---@field jni beat.DexJni
---@field activity fun(): beat.NativeActivity?

--- The loader the bridge classes come from: the APK's own when it carries them, or a dex written
--- out of the app's embedded copy.
---@param jni beat.DexJni
---@param activity beat.NativeActivity
local function classLoader(jni, activity)
	local own = jni.call(activity.clazz, "android/content/Context", "getClassLoader", "()Ljava/lang/ClassLoader;", "object")
	local found = pcall(jni.call, own, "java/lang/ClassLoader", "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;", "object", jni.string("beat.MediaBridge"))
	if found then return own end

	local files = jni.call(activity.clazz, "android/content/Context", "getFilesDir", "()Ljava/io/File;", "object")
	local directory = jni.tostring(jni.call(files, "java/io/File", "getAbsolutePath", "()Ljava/lang/String;", "object"))
	local file = directory .. "/media.dex"
	os.remove(file)
	local handle = assert(io.open(file, "wb"))
	handle:write(require("beat.app.media_dex"))
	handle:close()
	local dexFile = jni.new("java/io/File", "(Ljava/lang/String;)V", jni.string(file))
	jni.call(dexFile, "java/io/File", "setReadOnly", "()Z", "boolean")
	return jni.new("dalvik/system/DexClassLoader", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V", jni.string(file), jni.string(directory), nil, own)
end

--- Loads one of the dex's classes by its binary name, such as `beat.SystemBars`. The class is a
--- local reference, so the caller keeps it in a JNI frame and makes a global of anything that lives
--- longer than that frame.
---@param jni beat.DexJni
---@param activity beat.NativeActivity
---@param name string
---@return any class
function dex.class(jni, activity, name)
	local loader = classLoader(jni, activity)
	return jni.call(loader, "java/lang/ClassLoader", "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;", "object", jni.string(name))
end

return dex
