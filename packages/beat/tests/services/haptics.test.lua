-- What a press feels like, away from a phone: the table that decides which messages are felt and
-- how strongly, and the interval that keeps one press from being two clicks. The JNI itself is
-- only exercised on the device; the service does nothing off Android, which is also checked here.
local test = require("lde-test")
local Haptics = require("beat.app.services.system.haptics")

local function strengthOf(messageType)
	return Haptics.strength({ type = messageType })
end

test.it("answers a playback control with a tap", function()
	test.equal(strengthOf("togglePlay"), "tap")
	test.equal(strengthOf("play"), "tap")
	test.equal(strengthOf("pause"), "tap")
	test.equal(strengthOf("next"), "tap")
	test.equal(strengthOf("previous"), "tap")
	test.equal(strengthOf("skipGroup"), "tap")
	test.equal(strengthOf("playAlbum"), "tap")
	test.equal(strengthOf("jumpTrack"), "tap")
	test.equal(strengthOf("playlistAddTrack"), "tap")
end)

test.it("answers navigation, menus and toggles with a tick", function()
	test.equal(strengthOf("navigate"), "tick")
	test.equal(strengthOf("open"), "tick")
	test.equal(strengthOf("dismiss"), "tick")
	test.equal(strengthOf("toggleSidebar"), "tick")
	test.equal(strengthOf("toggleTagFilter"), "tick")
	test.equal(strengthOf("uiScale"), "tick")
	test.equal(strengthOf("mute"), "tick")
	test.equal(strengthOf("shuffle"), "tick")
	test.equal(strengthOf("shuffleMode"), "tick")
end)

test.it("answers removing something with a heavy click", function()
	test.equal(strengthOf("deletePlaylist"), "heavy")
	test.equal(strengthOf("playlistRemove"), "heavy")
	test.equal(strengthOf("playlistRemoveAlbum"), "heavy")
	test.equal(strengthOf("playlistAdderRemoveTrack"), "heavy")
	test.equal(strengthOf("deleteTag"), "heavy")
	test.equal(strengthOf("confirmDeleteTag"), "heavy")
	test.equal(strengthOf("deleteEqualizerPreset"), "heavy")
	test.equal(strengthOf("lastfmDisconnect"), "heavy")
end)

test.it("never feels scrolling, typing, dragging or the player's own messages", function()
	for _, messageType in ipairs({
		"scroll",
		"search",
		"seek",
		"volume",
		"equalizerGain",
		"pickHsv",
		"sidebarWidth",
		"hoverTag",
		"hoverPlaylist",
		"keep",
		"trackStarted",
		"trackEnded",
		"queueChanged",
		"progress",
		"track"
	}) do
		test.equal(strengthOf(messageType), nil, messageType .. " is not a press")
	end
end)

test.it("ignores a message that is not a table", function()
	test.equal(Haptics.strength(nil), nil)
	test.equal(Haptics.strength("togglePlay"), nil)
end)

test.it("allows one click every forty milliseconds", function()
	local haptics = Haptics.new()
	local start = 100

	test.truthy(haptics:due(start), "the first press is felt")
	haptics.lastAt = start
	test.falsy(haptics:due(start + 0.039), "a press 39 ms later is part of the same one")
	test.truthy(haptics:due(start + 0.040), "40 ms later is a press of its own")
end)

test.it("does nothing off Android", function()
	local haptics = Haptics.new()
	haptics:message({ type = "togglePlay" })
	haptics:tap()
	haptics:tick()
	haptics:heavy()

	test.equal(haptics.lastAt, nil, "no feedback was played")
	test.falsy(haptics.failed, "and nothing was marked broken")
end)
