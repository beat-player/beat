-- What the phone feels when something on the screen is pressed: the same short vibration a native
-- app answers a button with. It is asked for by the message a press came to rather than by any
-- view, so every control that uses the messages named below is felt and no view has to know that
-- haptics exist.
--
-- The vibration itself is Android's own touch feedback, played through the system's touch usage so
-- that turning touch feedback off in the phone's settings turns this off too. A desktop has no
-- such thing, and nothing here does anything there.
local wonderland = require("wonderland")
local platform = require("beat.platform")
local Log = require("beat.log")

local time = wonderland.time

-- Android's `VibrationEffect.EFFECT_CLICK`, `EFFECT_TICK` and `EFFECT_HEAVY_CLICK`. The effect is
-- a named constant rather than a length and strength of our own so it sounds like every other
-- button on the phone.
local CLICK = 0
local TICK = 2
local HEAVY = 5

--- The usage the effect is played as: `VibrationAttributes.USAGE_TOUCH`. This is what makes the
--- system's "touch feedback" setting the one that governs it.
local USAGE_TOUCH = 18

-- No two clicks within this many seconds. A press that sends a message which immediately sends
-- another -- opening a menu as it navigates, closing a panel as it acts -- is one press and should
-- be one click.
local INTERVAL = 0.040

---@alias beat.HapticsStrength "tap" | "tick" | "heavy"

--- Which strength a message from the screen gets. Only presses and the confirmations of them are
--- here: what a finger would expect a phone to answer. Scrolling, typing, dragging a slider and the
--- player's own announcements are not, so those are absent rather than filtered later.
---
--- A tick is the lightest: navigation, menus opening, toggles and settings choices. A tap is the
--- ordinary button -- playback controls and the confirmations that start something. A heavy click
--- is a destructive choice, so it is worth noticing before the dialog that follows.
---@type table<string, beat.HapticsStrength>
local STRENGTH = {
	-- Playback: the controls a finger presses most.
	togglePlay = "tap",
	play = "tap",
	pause = "tap",
	stop = "tap",
	next = "tap",
	previous = "tap",
	skipGroup = "tap",
	playAlbum = "tap",
	playTrack = "tap",
	playArtist = "tap",
	playPlaylist = "tap",
	playPlaylistTrack = "tap",
	jumpTrack = "tap",
	-- The queue and the playlists: adding something is a confirmed action.
	queueAlbum = "tap",
	playlistAddAlbum = "tap",
	playlistAddTrack = "tap",
	addToPlaylist = "tap",
	rateTrack = "tap",
	rateAlbum = "tap",
	-- Navigation and the panels it opens.
	navigate = "tick",
	back = "tick",
	forward = "tick",
	dismiss = "tick",
	open = "tick",
	escape = "tick",
	confirmLeave = "tick",
	cancelLeave = "tick",
	-- Search: the buttons around the field, never what is typed into it.
	openSearch = "tick",
	focusPageSearch = "tick",
	clearSearch = "tick",
	clearPageSearch = "tick",
	-- Settings: every toggle, segmented choice and picker is a tick.
	toggleSidebar = "tick",
	toggleView = "tick",
	sort = "tick",
	theme = "tick",
	accent = "tick",
	uiScale = "tick",
	reduceMotion = "tick",
	minimizeToTray = "tick",
	updateChannel = "tick",
	checkForUpdates = "tick",
	checkUpdates = "tick",
	pluginEnabled = "tick",
	pluginSetting = "tick",
	-- Playback toggles and the panels they open.
	mute = "tick",
	shuffle = "tick",
	shuffleMode = "tick",
	["repeat"] = "tick",
	toggleVolume = "tick",
	toggleQueue = "tick",
	toggleMore = "tick",
	toggleEqualizer = "tick",
	expandNowPlaying = "tick",
	-- Tag filters and tags.
	toggleTagFilter = "tick",
	tagFilterMatch = "tick",
	clearTagFilter = "tick",
	toggleItemTag = "tick",
	createTag = "tap",
	editTag = "tick",
	renameTag = "tap",
	cancelTagEdit = "tick",
	-- Playlists and their dialogs.
	createPlaylist = "tap",
	playlistDraftTag = "tick",
	playlistDraftMatch = "tick",
	-- The equalizer's presets: opening one is navigation, saving a name is a confirmation.
	equalizerPreset = "tick",
	newEqualizerPreset = "tick",
	editEqualizerPreset = "tick",
	saveEqualizerPresetRename = "tap",
	cancelEqualizerPresetRename = "tick",
	confirmAccent = "tap",
	-- Scanning and the folder picker.
	startScan = "tap",
	rescan = "tap",
	cancelScan = "tick",
	chooseFolder = "tick",
	cancelFolders = "tick",
	folderUp = "tick",
	folderOpen = "tick",
	folderSelect = "tick",
	folderGo = "tick",
	onboardingBrowse = "tick",
	onboardingWelcome = "tick",
	libraryAddFolder = "tap",
	hideScanIsland = "tick",
	showScanIsland = "tick",
	dismissScanSummary = "tick",
	taskCancel = "tick",
	taskDismiss = "tick",
	-- Last.fm's settings controls.
	lastfmConnect = "tick",
	lastfmCancel = "tick",
	lastfmOpenAuth = "tick",
	lastfmEnabled = "tick",
	-- Toasts and links.
	dismissToast = "tick",
	openURL = "tick",
	openPluginsFolder = "tick",
	-- Updates.
	applyUpdate = "tap",
	relaunchUpdate = "tap",
	restartApp = "tick",
	-- Removing something is the one press with a heavier answer.
	deletePlaylist = "heavy",
	playlistRemove = "heavy",
	playlistRemoveAlbum = "heavy",
	playlistAdderRemoveTrack = "heavy",
	deleteTag = "heavy",
	confirmDeleteTag = "heavy",
	deleteEqualizerPreset = "heavy",
	lastfmDisconnect = "heavy"
}

-- The Java objects the phone is vibrated through: the Vibrator, the attributes every effect is
-- played with, and one effect for each strength. They are global references kept for the life of
-- the process, because the JVM's classes and the vibrator do not change when the app's services are
-- set up again, and a second Vibrator would only be the same one.
---@class beat.HapticsJava
---@field vibrator ffi.cdata*
---@field attributes ffi.cdata*
---@field effects table<beat.HapticsStrength, ffi.cdata*>

---@type beat.HapticsJava?
local shared

---@class beat.HapticsService: beat.Service
---@field lastAt number? # When the last click was played
---@field failed boolean # Loading the phone's vibrator failed once; it is not tried again
local Haptics = {}
Haptics.__index = Haptics

---@return beat.HapticsService
function Haptics.new()
	return setmetatable({ lastAt = nil, failed = false }, Haptics)
end

--- Loads the phone's Vibrator and the effects, once.
---@return boolean ok
---@return string? err
local function load()
	if shared ~= nil then return true end

	local ok, err = pcall(function()
		local android = require("androidapi")
		local jni = android.jni
		local activity = assert(android.activity())
		local loaded, frameError = jni.frame(function()
			local manager = jni.call(
				activity.clazz,
				"android/content/Context",
				"getSystemService",
				"(Ljava/lang/String;)Ljava/lang/Object;",
				"object",
				jni.string("vibrator_manager")
			)
			if manager == nil then error("no vibrator manager", 0) end

			local vibrator = jni.call(
				manager,
				"android/os/VibratorManager",
				"getDefaultVibrator",
				"()Landroid/os/Vibrator;",
				"object"
			)
			if vibrator == nil then error("no vibrator", 0) end

			local attributes = jni.callStatic(
				"android/os/VibrationAttributes",
				"createForUsage",
				"(I)Landroid/os/VibrationAttributes;",
				USAGE_TOUCH
			)
			local function effect(code)
				return jni.callStatic(
					"android/os/VibrationEffect",
					"createPredefined",
					"(I)Landroid/os/VibrationEffect;",
					code
				)
			end

			return {
				vibrator = jni.global(vibrator),
				attributes = jni.global(attributes),
				effects = {
					tap = jni.global(effect(CLICK)),
					tick = jni.global(effect(TICK)),
					heavy = jni.global(effect(HEAVY))
				}
			}
		end, 8)

		if loaded == nil then error(frameError or "the vibrator did not load", 0) end
		shared = loaded --[[@as beat.HapticsJava]]
	end)

	if not ok then return false, tostring(err) end
	return true
end

---@param self beat.HapticsService
---@param err string?
local function disable(self, err)
	if self.failed then return end
	self.failed = true
	Log.write("warn", "no haptic feedback: " .. tostring(err))
end

--- Whether a press at `now` may be felt: one every `INTERVAL` seconds. Exported because it is the
--- part of this service a test can drive without a phone.
---@param now number
---@return boolean
function Haptics:due(now)
	return self.lastAt == nil or now - self.lastAt >= INTERVAL
end

--- Plays one strength of feedback, if the phone can and no click was played a moment ago.
---@param strength beat.HapticsStrength
function Haptics:play(strength)
	if not platform.android or self.failed then return end

	local now = time.now()
	if not self:due(now) then return end
	self.lastAt = now

	if shared == nil then
		local ok, err = load()
		if not ok then disable(self, err) end
		if shared == nil then return end
	end

	local state = shared
	local ok, err = pcall(function()
		local jni = require("androidapi").jni
		jni.call(
			state.vibrator,
			"android/os/Vibrator",
			"vibrate",
			"(Landroid/os/VibrationEffect;Landroid/os/VibrationAttributes;)V",
			"void",
			state.effects[strength],
			state.attributes
		)
	end)
	if not ok then disable(self, err) end
end

function Haptics:tap() self:play("tap") end

function Haptics:tick() self:play("tick") end

function Haptics:heavy() self:play("heavy") end

--- What a message from the screen is worth, or nothing when it is not a press. Automatic messages
--- -- a track ending, a scan reporting, a timer -- are not in the table, so they never reach the
--- phone even though they pass through the same messages.
---@param message any
---@return beat.HapticsStrength?
function Haptics.strength(message)
	if type(message) ~= "table" then return nil end
	return STRENGTH[message.type]
end

--- Feels a message if it came from a press. Called for what the screen sends rather than for every
--- message the app delivers: a service's `emit` is the app talking to itself.
---@param message any
function Haptics:message(message)
	local strength = Haptics.strength(message)
	if strength ~= nil then self:play(strength) end
end

--- The messages that are felt, by strength, for a test to read the table it asserts against.
Haptics.strengths = STRENGTH

return Haptics
