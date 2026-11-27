-- The empty-library card both Home and Library draw: the same words, the folder a scan looked in,
-- the two ways to fill it, and the scan's own progress while a folder is being read.
local test = require("lde-test")
local wonderland = require("wonderland")
local elements = require("wonderland.element")
local ui = require("beat-ui")
local themeModule = require("beat.app.services.appearance.theme")
local libraryEmpty = require("beat.app.components.library_empty")

local theme = themeModule.new()

---@param width number?
---@param mobile boolean?
local function context(width, mobile)
	local windowWidth = width or 1200
	return ui.Context.new({
		theme = theme,
		width = windowWidth,
		height = 720,
		contentWidth = windowWidth - (mobile and 32 or 320),
		contentHeight = 720 - 64,
		mobile = mobile == true
	})
end

---@param opts { root: string?, scan: table? }
local function appWith(opts)
	return {
		services = {
			settings = { values = { root = opts.root } },
			library = { current = nil },
			scan = opts.scan or { job = nil, fraction = function() return 0 end }
		}
	}
end

local pointers = elements.pointers

--- The first element in a built tree whose line is `value`.
---@param node wonderland.Element
---@param value string
---@return wonderland.Element?
local function findText(node, value)
	if elements.textOf(node) == value then return node end
	local child = node.childFirst
	for _ = 1, node.childCount do
		local nextChild = pointers[child]
		local found = findText(nextChild, value)
		if found ~= nil then return found end
		child = nextChild.nextSibling
	end
	return nil
end

--- The message the button labelled `label` sends.
---@param node wonderland.Element
---@param label string
---@return table?
local function messageFor(node, label)
	if node.onclick ~= 0 and node.childCount == 1 then
		local only = pointers[node.childFirst]
		if only ~= nil and elements.textOf(only) == label then return elements.callbacks[node.onclick] end
	end
	local child = node.childFirst
	for _ = 1, node.childCount do
		local nextChild = pointers[child]
		local found = messageFor(nextChild, label)
		if found ~= nil then return found end
		child = nextChild.nextSibling
	end
	return nil
end

test.it("the empty card names the folder and offers both ways to fill it", function()
	local view = libraryEmpty.view(appWith({ root = "/tmp" }), context())
	local lines = {
		"Your library is empty",
		"Nothing playable found in this folder yet.",
		"/tmp",
		"Choose a folder",
		"Rescan",
		"Supported: FLAC · MP3 · Opus · OGG · WAV · M4A"
	}
	for _, value in ipairs(lines) do
		test.truthy(findText(view, value) ~= nil, "the card shows " .. value)
	end
	test.equal(assert(messageFor(view, "Choose a folder")).type, "chooseFolder", "the primary action asks for a folder")
	test.equal(assert(messageFor(view, "Rescan")).type, "rescan", "the secondary action rescans the root")
end)

test.it("without a folder the card asks for one and offers no rescan", function()
	local view = libraryEmpty.view(appWith({ root = nil }), context())
	test.truthy(findText(view, "Choose a folder to start your library.") ~= nil)
	test.truthy(findText(view, "Rescan") == nil, "there is no root to rescan")
	test.equal(assert(messageFor(view, "Choose a folder")).type, "chooseFolder")
end)

test.it("a running scan is the same card with its progress and the file it is on", function()
	local progress = {
		phase = "inspect",
		files = 412,
		inspected = 168,
		tracks = 41,
		skipped = 3,
		errors = {},
		current = "/tmp/Library/Slow Riot/02 - Bad Decisions.flac"
	}
	---@type table
	local scan = {
		job = { progress = function() return progress end },
		fraction = function() return 0.4 end
	}
	local view = libraryEmpty.view(appWith({ root = "/tmp", scan = scan }), context())
	test.truthy(findText(view, "Reading your music") ~= nil)
	test.truthy(findText(view, "41 tracks found · 168 / 412 files") ~= nil)
	test.truthy(findText(view, "3 files skipped") ~= nil)
	test.truthy(findText(view, "02 - Bad Decisions.flac") ~= nil)
	test.truthy(findText(view, "Choose a folder") == nil, "a scan does not offer a second folder")
	test.equal(assert(messageFor(view, "Cancel scan")).type, "cancelScan")
end)

test.it("a scan that is still finding files counts no tracks yet", function()
	local progress = { phase = "enumerate", files = 0, inspected = 0, tracks = 0, skipped = 0, errors = {}, current = nil }
	---@type table
	local scan = {
		job = { progress = function() return progress end },
		fraction = function() return 0 end
	}
	local view = libraryEmpty.view(appWith({ root = "/tmp", scan = scan }), context())
	test.truthy(findText(view, "Finding your music") ~= nil)
	test.truthy(findText(view, "0 tracks found · 0 / 0 files") ~= nil)
	test.truthy(findText(view, "skipped") == nil, "nothing has failed yet")
end)

test.it("the scan card follows the file it is on", function()
	local progress = {
		phase = "inspect",
		files = 20,
		inspected = 4,
		tracks = 2,
		skipped = 0,
		errors = {},
		current = "/tmp/Library/Slow Riot/01 - First.flac"
	}
	---@type table
	local scan = {
		job = { progress = function() return progress end },
		fraction = function() return 0.2 end
	}
	local app = appWith({ root = "/tmp", scan = scan })
	test.truthy(findText(libraryEmpty.view(app, context()), "01 - First.flac") ~= nil)

	progress.current = "/tmp/Library/Slow Riot/02 - Second.flac"
	local nextView = libraryEmpty.view(app, context())
	test.truthy(findText(nextView, "02 - Second.flac") ~= nil, "the chip names the new file")
	test.truthy(findText(nextView, "01 - First.flac") == nil, "and not the one before it")
end)
