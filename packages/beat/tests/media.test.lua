-- The phone's player controls, away from a phone: the command the MediaBridge queue carries is
-- turned into playback actions here, so the X the notification and the shade show ends the sound
-- and takes the app out without a device to press it on. The JNI itself is only exercised there.
local test = require("lde-test")
local platform = require("beat.platform")
local App = require("beat.app")
local Media = require("beat.app.services.system.media")

local realAndroid = platform.android
local realAndroidApi = package.loaded["androidapi"]

test.afterEach(function()
	platform.android = realAndroid
	package.loaded["androidapi"] = realAndroidApi
	package.loaded["beat.app.services.system.media"] = nil
end)

--- What the fake bridge was asked, and in what order the Lua side acted.
---@class TestBridge
---@field shutdowns number
---@field commands number[]
---@field at number
---@field polls number?
local function fakeBridge()
	local bridge = { shutdowns = 0, commands = { 10, -1 }, at = 1, polls = 0 } -- CLOSE, then nothing
	return bridge
end

---@param bridge TestBridge
---@param order string[]
local function fakeApi(bridge, order)
	local function call(_object, _className, name)
		if name == "newInstance" then return bridge end
		if name == "getAsInt" then
			bridge.polls += 1
			local command = bridge.commands[bridge.at]
			bridge.at += 1
			return command or -1
		end
		if name == "run" then
			-- The bridge's Runnable: the notification, service and session go now.
			bridge.shutdowns += 1
			order[#order + 1] = "release"
		end
		return nil
	end

	return {
		activity = function() return { clazz = {} } end,
		jni = {
			call = call,
			frame = function(body)
				local ok, value = pcall(body)
				if not ok then return nil, value end
				return value
			end,
			new = function() return {} end,
			string = function(value) return value end,
			global = function(value) return value end
		}
	}
end

test.it("the player's X pauses, drops the media session and asks the app to leave", function()
	local bridge = fakeBridge()
	local order = {}
	package.loaded["androidapi"] = fakeApi(bridge, order)
	platform.android = true

	local paused = false
	local pauseCount = 0
	local track = { id = 1, title = "Track", artist = "Artist", album = "Album", albumId = 1 }
	local player = {}
	function player:isPlaying() return not paused end
	function player:isAudible() return not paused end
	function player:position() return 0 end
	function player:duration() return 0 end
	function player:current() return paused and nil or track end

	local playback = { player = player }
	function playback:pause()
		-- Pausing writes where listening got to, so the next launch carries on there.
		pauseCount += 1
		paused = true
		order[#order + 1] = "pause"
	end

	local messages = {}
	local media = Media.new({
		playback = playback,
		library = {},
		settings = { values = { pauseForOtherAudio = true } },
		emit = function(message)
			messages[#messages + 1] = message
			order[#order + 1] = message.type
		end
	})

	media:step(0)

	test.equal(pauseCount, 1, "the sound stopped")
	test.equal(bridge.shutdowns, 1, "the notification, the foreground service and the session went")
	test.equal(#messages, 1, "one message left the service")
	test.equal(messages[1].type, "leave", "the app is asked to quit")
	test.equal(table.concat(order, " "), "pause release leave", "in that order: nothing plays after the X")
end)

test.it("a leave message writes what services hold and stops the loop", function()
	local app = setmetatable({}, { __index = App })
	local flushed, exits = 0, 0
	app.flush = function() flushed += 1 end
	app.loopHandler = { exit = function() exits += 1 end }

	app:route({ type = "leave" })

	test.equal(flushed, 1, "the session is saved")
	test.equal(exits, 1, "and the app leaves")
end)

test.it("polls a paused player four times a second and a playing one ten", function()
	local bridge = fakeBridge()
	bridge.commands = {}
	package.loaded["androidapi"] = fakeApi(bridge, {})
	platform.android = true

	local playing = false
	local track = { id = 1, title = "Track", artist = "Artist", album = "Album", albumId = 1 }
	local player = {}
	function player:isPlaying() return playing end
	function player:isAudible() return playing end
	function player:position() return 0 end
	function player:duration() return 0 end
	function player:current() return track end

	local media = Media.new({
		playback = { player = player },
		library = {},
		settings = { values = { pauseForOtherAudio = true } },
		emit = function() end
	})

	local _, pausedBusy = media:step(0)
	test.equal(pausedBusy, 0.25, "a paused player has nothing moving to report ten times a second")
	test.equal(bridge.polls, 1, "the queue was read on the first tick")

	media:step(0.1)
	test.equal(bridge.polls, 1, "a tenth of a second is not yet a paused poll")

	media:step(0.25)
	test.equal(bridge.polls, 2, "a quarter second is")

	playing = true
	local _, playingBusy = media:step(0.3)
	test.equal(playingBusy, 0.1, "a playing player keeps the tenth-second poll")

	media:step(0.34)
	test.equal(bridge.polls, 2, "and is not read early")

	media:step(0.4)
	test.equal(bridge.polls, 3)
end)
