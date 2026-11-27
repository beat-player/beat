-- What the phone shows of beat outside the app: the lock screen's player, the media controls in the
-- notification shade, and what a headset's buttons and a watch control. All of it is one Android
-- media session and its notification.
--
-- A media session answers its controls through a Java callback class, and a NativeActivity APK has
-- no Java of its own, so the class (android/beat/MediaBridge.java) is a dex that is written to the
-- app's private storage and loaded at run time (see system/dex.lua). Lua drives it through the two
-- framework interfaces it implements: a Consumer that takes what is playing as a Bundle, and an
-- IntSupplier that hands back the controls pressed since the last tick. Audio focus and a media
-- stream at zero arrive through that same queue, because only Java can hear them. Off Android this
-- service does nothing.
local platform = require("beat.platform")
local dex = require("beat.app.services.system.dex")

-- What `MediaBridge.getAsInt` answers with; a seek is -2 - the position in milliseconds.
local NONE = -1
local PLAY = 1
local PAUSE = 2
local NEXT = 3
local PREVIOUS = 4
local STOP = 5
-- What the bridge asks for when another app takes audio focus, or the media stream falls silent.
local FOCUS_PAUSE = 6
local FOCUS_RESUME = 7
local FOCUS_LOSS = 8
local VOLUME_ZERO = 9

-- How far the playhead may be from where the session's last report puts it before it is told
-- again: the system moves its own copy on at the playback speed, so only a seek or a stall drifts.
local DRIFT = 1.5

-- The longest the Java command queue is left alone while a track is loaded.
local COMMAND_INTERVAL = 0.1

-- The bridge the process loaded, kept across the app being set up again: a second MediaBridge
-- would be a second session, and a second player on the lock screen.
---@type ffi.cdata*?
local shared = nil

---@class beat.MediaService: beat.Service
---@field playback beat.PlaybackService
---@field library beat.LibraryService
---@field settings beat.SettingsService
---@field bridge ffi.cdata*? # The MediaBridge, as a global reference
---@field failed boolean # Loading the bridge failed once; it is not tried every tick
---@field sentTrackId number? # The track the last report named; nil when none was sent
---@field sentDuration number # The whole seconds the last report's duration was compared by
---@field sentPosition number
---@field sentAt number
---@field sentPlaying boolean
---@field sentPause boolean? # Whether the last report said other audio may pause playback
---@field lastCommandAt number # When the Java control queue was last polled
---@field pausedByFocus boolean # This service paused playback for a transient loss, so the gain resumes it
local Media = {}
Media.__index = Media
Media.needs = { "playback", "library", "settings" }

---@param deps { playback: beat.PlaybackService, library: beat.LibraryService, settings: beat.SettingsService }
---@return beat.MediaService
function Media.new(deps)
	return setmetatable({
		playback = deps.playback,
		library = deps.library,
		settings = deps.settings,
		bridge = nil,
		failed = false,
		sentTrackId = nil,
		sentDuration = 0,
		sentPosition = 0,
		sentAt = 0,
		sentPlaying = false,
		sentPause = nil,
		lastCommandAt = -1,
		pausedByFocus = false
	}, Media)
end

--- Loads MediaBridge and starts it on the activity.
---@return ffi.cdata* bridge
local function loadBridge()
	---@diagnostic disable-next-line: missing-module
	local android = require("androidapi") --[[@as beat.AndroidApi]]
	local jni = android.jni
	local activity = assert(android.activity())
	local bridge, err = jni.frame(function()
		local class = dex.class(jni, activity, "beat.MediaBridge")
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
	---@diagnostic disable-next-line: missing-module
	local android = require("androidapi") --[[@as beat.AndroidApi]]
	local jni = android.jni
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

		putBoolean("pauseForOtherAudio", self.settings.values.pauseForOtherAudio ~= false)
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
	---@diagnostic disable-next-line: missing-module
	local android = require("androidapi") --[[@as beat.AndroidApi]]
	local jni = android.jni
	local bridge = assert(self.bridge)
	local playback = self.playback
	local pauseForOtherAudio = self.settings.values.pauseForOtherAudio ~= false
	for _ = 1, 16 do
		local command = jni.call(bridge, "java/util/function/IntSupplier", "getAsInt", "()I", "int") --[[@as number]]
		if command == NONE then return end

		local playing = playback.player:isPlaying()
		if command == PLAY then
			if not playing then playback:toggle() end
		elseif command == PAUSE or command == STOP then
			-- Paused from a control, not by a focus loss: a later gain must not undo it.
			self.pausedByFocus = false
			if playing then playback:toggle() end
		elseif command == NEXT then
			playback.player:next()
		elseif command == PREVIOUS then
			playback.player:previous()
		elseif command == FOCUS_PAUSE then
			-- Another app took focus for a while: pause, and let its gain start this again.
			if pauseForOtherAudio then
				self.pausedByFocus = playing
				if playing then playback:pause() end
			end
		elseif command == FOCUS_RESUME then
			if pauseForOtherAudio and self.pausedByFocus then
				self.pausedByFocus = false
				if not playback.player:isPlaying() then playback:play() end
			end
		elseif command == FOCUS_LOSS then
			-- Another app took focus for good: pause, and only the listener starts it again.
			if pauseForOtherAudio then
				self.pausedByFocus = false
				if playing then playback:pause() end
			end
		elseif command == VOLUME_ZERO then
			-- The media volume fell to nothing: pause, and turning it back up does not resume.
			if pauseForOtherAudio and playing then playback:pause() end
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

	-- The controls are a Java queue polled through JNI, and only a session with something in it can
	-- use them: with no track the app is not the phone's player. Four times a second is enough for
	-- a button or a focus change to be felt as a press.
	local player = self.playback.player
	local track = player:current()
	if track ~= nil and now - self.lastCommandAt >= COMMAND_INTERVAL then
		self.lastCommandAt = now
		takeCommands(self)
		track = player:current()
	end

	local pauseForOtherAudio = self.settings.values.pauseForOtherAudio ~= false
	if track == nil then
		if self.sentTrackId ~= nil then
			self.sentTrackId = nil
			report(self, { active = false })
		end
		return false, false
	end

	-- What the status reports is what is heard: a loading or buffering track is shown as paused
	-- until its first frames reach the device.
	local playing = player:isAudible()
	local position = player:position()
	local duration = player:duration()
	local seconds = math.floor(duration)
	local expected = self.sentPosition + (self.sentPlaying and (now - self.sentAt) or 0)
	if track.id ~= self.sentTrackId
		or playing ~= self.sentPlaying
		or seconds ~= self.sentDuration
		or math.abs(position - expected) > DRIFT
		or pauseForOtherAudio ~= self.sentPause
	then
		local library = self.library.current
		local album = library ~= nil and library:album(track.albumId) or nil
		self.sentTrackId, self.sentDuration, self.sentPosition, self.sentAt, self.sentPlaying, self.sentPause =
			track.id, seconds, position, now, playing, pauseForOtherAudio
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
	self.sentTrackId = nil
	report(self, { active = false })
end

--- The setting is the bridge's to act on: every report carries it, and a change is reported on
--- the next tick even when nothing about playback moved.
Media.on = {
	---@param self beat.MediaService
	---@param message beat.PauseForOtherAudioMessage
	pauseForOtherAudio = function(self, message)
		self.settings.values.pauseForOtherAudio = message.value == true
		-- Opting out cancels a resume a transient loss was holding for; the listener decides.
		if not self.settings.values.pauseForOtherAudio then self.pausedByFocus = false end
		self.settings:changed()
	end
}

return Media
