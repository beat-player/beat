-- The seek bar's two clocks and the slider between them: what they show while a track is being
-- opened, after it has been heard, and while a seek refills the ring at a new place.
local test = require("lde-test")
local elements = require("wonderland.element")
local themeModule = require("beat.app.services.appearance.theme")
local progress = require("beat.app.components.progress")

local theme = themeModule.new()
local app = { services = { appearance = { theme = theme } } }
local pointers = elements.pointers

---@param player beat.Player
---@param track beat.Track
---@return wonderland.Element
local function view(player, track)
	return progress.view(app, { track = track, player = player, width = theme:px(360) })
end

--- Every line of text in a built tree, in order.
---@param node wonderland.Element
---@return string[]
local function lines(node)
	local found = {}
	local child = node.childFirst
	for _ = 1, node.childCount do
		local nextChild = pointers[child]
		local value = elements.textOf(nextChild)
		if value ~= nil then found[#found + 1] = value end
		for _, line in ipairs(lines(nextChild)) do found[#found + 1] = line end
		child = nextChild.nextSibling
	end
	return found
end

--- The slider between the two clocks.
---@param node wonderland.Element
---@return wonderland.Element
local function sliderOf(node)
	local child = node.childFirst
	local nextChild = pointers[child]
	return pointers[nextChild.nextSibling]
end

---@param opts { loading: boolean, heard: boolean, duration: number, position: number }
---@return table
local function player(opts)
	return {
		isLoading = function() return opts.loading end,
		hasHeard = function() return opts.heard end,
		duration = function() return opts.duration end,
		position = function() return opts.position end
	}
end

---@type beat.Track
local track = { duration = 180 }

test.it("shows placeholders while a new track has had no audio", function()
	local bar = view(player({ loading = true, heard = false, duration = 0, position = 0 }), track)
	local text = lines(bar)
	test.equal(#text, 2)
	test.equal(text[1], "--:--", "the elapsed clock waits for audio")
	test.equal(text[2], "--:--", "and so does the length")
	test.equal(sliderOf(bar).sliderValue, 0, "the bar holds at the start")
end)

test.it("shows the real clocks and the target as soon as a seek is made", function()
	local bar = view(player({ loading = false, heard = true, duration = 180, position = 65 }), track)
	local text = lines(bar)
	test.equal(text[1], "1:05", "the elapsed clock jumps to the seek target")
	test.equal(text[2], "3:00", "and the length stays the track's")
	test.equal(sliderOf(bar).sliderValue, 65, "the bar jumps to the target too")
end)

test.it("keeps the clocks real when a heard track buffers again", function()
	-- A seek that the thread is refilling, or a guest device stalling mid-track: once the track
	-- has been heard, waiting for data is not a reason to blank the two clocks.
	local bar = view(player({ loading = true, heard = true, duration = 180, position = 65 }), track)
	local text = lines(bar)
	test.equal(text[1], "1:05")
	test.equal(text[2], "3:00")
end)
