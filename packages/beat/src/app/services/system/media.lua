-- What the phone shows of beat outside the app: the lock screen's player, the media controls in the
-- notification shade, and what a headset's buttons and a watch control. All of it is one Android
-- media session and its notification.
--
-- A media session answers its controls through a Java callback class, and a NativeActivity APK has
-- no Java of its own, so the class (android/beat/MediaBridge.java) is a dex that is written to the
-- app's private storage and loaded at run time. Lua drives it through the two framework interfaces
-- it implements: a Consumer that takes what is playing as a Bundle, and an IntSupplier that hands
-- back the controls pressed since the last tick. Off Android this service does nothing.
local platform = require("beat.platform")

-- What `MediaBridge.getAsInt` answers with; a seek is -2 - the position in milliseconds.
local NONE = -1
local PLAY = 1
local PAUSE = 2
local NEXT = 3
local PREVIOUS = 4
local STOP = 5

-- How far the playhead may be from where the session's last report puts it before it is told
-- again: the system moves its own copy on at the playback speed, so only a seek or a stall drifts.
local DRIFT = 1.5

-- The bridge the process loaded, kept across the app being set up again: a second MediaBridge
-- would be a second session, and a second player on the lock screen.
---@type ffi.cdata*?
local shared = nil

---@class beat.MediaService: beat.Service
---@field playback beat.PlaybackService
---@field library beat.LibraryService
---@field bridge ffi.cdata*? # The MediaBridge, as a global reference
---@field failed boolean # Loading the bridge failed once; it is not tried every tick
---@field sentKey string? # What the last report said, apart from the position
---@field sentPosition number
---@field sentAt number
---@field sentPlaying boolean
local Media = {}
Media.__index = Media
Media.needs = { "playback", "library" }

---@param deps { playback: beat.PlaybackService, library: beat.LibraryService }
---@return beat.MediaService
function Media.new(deps)
	return setmetatable({
		playback = deps.playback,
		library = deps.library,
		bridge = nil,
		failed = false,
		sentKey = nil,
		sentPosition = 0,
		sentAt = 0,
		sentPlaying = false
	}, Media)
end

--- Writes the dex where only this app can reach it, loads MediaBridge from it and starts it on the
--- activity. Android 14 refuses to load a dex that can still be written, so the file is made
--- read-only first; a file left by the last launch is replaced, since it may be an older build's.
---@return ffi.cdata* bridge
local function loadBridge()
	local android = require("androidapi")
	local jni = android.jni
	local activity = assert(android.activity())
	local directory = jni.frame(function()
		local files = jni.call(activity.clazz, "android/content/Context", "getFilesDir", "()Ljava/io/File;", "object")
		return jni.tostring(jni.call(files, "java/io/File", "getAbsolutePath", "()Ljava/lang/String;", "object"))
	end)
	if directory == nil then error("the app has no files directory", 0) end
	---@cast directory string
	local file = directory .. "/media.dex"

	os.remove(file)
	local handle = assert(io.open(file, "wb"))
	handle:write(require("beat.app.media_dex"))
	handle:close()

	local bridge, err = jni.frame(function()
		local dex = jni.new("java/io/File", "(Ljava/lang/String;)V", jni.string(file))
		jni.call(dex, "java/io/File", "setReadOnly", "()Z", "boolean")
		local parent = jni.call(activity.clazz, "android/content/Context", "getClassLoader", "()Ljava/lang/ClassLoader;", "object")
		local loader = jni.new("dalvik/system/DexClassLoader", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V", jni.string(file), jni.string(directory), nil, parent)
		local class = jni.call(loader, "java/lang/ClassLoader", "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;", "object", jni.string("beat.MediaBridge"))
		local instance = jni.call(class, "java/lang/Class", "newInstance", "()Ljava/lang/Object;", "object")
		jni.call(instance, "java/util/function/Consumer", "accept", "(Ljava/lang/Object;)V", "void", activity.clazz)
		return jni.global(instance)
	end)
	if bridge == nil then error(err or "MediaBridge did not load", 0) end
	return bridge --[[@as ffi.cdata*]]
end

---@param self beat.MediaService
---@param state { active: boolean, title: string?, artist: string?, album: string?, art: string?, duration: number?, position: number?, playing: boolean? }
local function report(self, state)
	local jni = require("androidapi").jni
	local bridge = assert(self.bridge)
	local _, err = jni.frame(function()
		local bundle = jni.new("android/os/Bundle", "()V")
		local function putString(key, value)
			jni.call(bundle, "android/os/BaseBundle", "putString", "(Ljava/lang/String;Ljava/lang/String;)V", "void", jni.string(key), jni.string(value))
		end
		local function putLong(key, value)
			jni.call(bundle, "android/os/BaseBundle", "putLong", "(Ljava/lang/String;J)V", "void", jni.string(key), math.floor(value))
		end
		local function putBoolean(key, value)
			jni.call(bundle, "android/os/BaseBundle", "putBoolean", "(Ljava/lang/String;Z)V", "void", jni.string(key), value)
		end

		putBoolean("active", state.active)
		if state.active then
			putString("title", state.title or "")
			putString("artist", state.artist or "")
			putString("album", state.album or "")
			if state.art ~= nil then putString("art", state.art) end
			putLong("duration", (state.duration or 0) * 1000)
			putLong("position", (state.position or 0) * 1000)
			putBoolean("playing", state.playing == true)
		end
		jni.call(bridge, "java/util/function/Consumer", "accept", "(Ljava/lang/Object;)V", "void", bundle)
	end, 24)
	if err ~= nil then require("beat.log").write("warn", "media session update failed: " .. tostring(err)) end
end

--- Carries out what the lock screen, the shade or a headset asked for since the last tick.
---@param self beat.MediaService
local function takeCommands(self)
	local jni = require("androidapi").jni
	local bridge = assert(self.bridge)
	local playback = self.playback
	for _ = 1, 16 do
		local command = jni.call(bridge, "java/util/function/IntSupplier", "getAsInt", "()I", "int")
		if command == NONE then return end

		local playing = playback.player:isPlaying()
		if command == PLAY then
			if not playing then playback:toggle() end
		elseif command == PAUSE or command == STOP then
			if playing then playback:toggle() end
		elseif command == NEXT then
			playback.player:next()
		elseif command == PREVIOUS then
			playback.player:previous()
		elseif command <= -2 then
			playback.player:seek((-2 - command) / 1000)
		end
	end
end

---@param now number
---@return boolean changed
---@return boolean busy
function Media:step(now)
	if not platform.android or self.failed then return false, false end

	if self.bridge == nil then
		if shared == nil then
			local ok, bridge = pcall(loadBridge)
			if not ok then
				self.failed = true
				require("beat.log").write("warn", "no media session: " .. tostring(bridge))
				return false, false
			end
			shared = bridge
		end
		self.bridge = shared
	end

	takeCommands(self)

	local player = self.playback.player
	local track = player:current()
	if track == nil then
		if self.sentKey ~= "" then
			self.sentKey = ""
			report(self, { active = false })
		end
		return false, false
	end

	local playing = player:isPlaying()
	local position = player:position()
	local duration = player:duration()
	local key = string.format("%d|%s|%d", track.id, tostring(playing), math.floor(duration))
	local expected = self.sentPosition + (self.sentPlaying and (now - self.sentAt) or 0)
	if key ~= self.sentKey or math.abs(position - expected) > DRIFT then
		local library = self.library.current
		local album = library ~= nil and library:album(track.albumId) or nil
		self.sentKey, self.sentPosition, self.sentAt, self.sentPlaying = key, position, now, playing
		report(self, {
			active = true,
			title = track.title,
			artist = track.artist,
			album = track.album,
			art = album ~= nil and album.coverCache or nil,
			duration = duration,
			position = position,
			playing = playing
		})
	end
	return false, false
end

--- The app is going: the lock screen should not keep a player for a process that has gone.
function Media:flush()
	if self.bridge == nil then return end
	self.sentKey = ""
	report(self, { active = false })
end

return Media
