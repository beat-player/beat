-- The grouped settings list: a row's inset belongs to the row, so a clickable row lights its
-- padding as well as its words, and a plain row still places its words where a clickable one
-- does. The styles are read back after they are interned, which is what the layout will see.
local test = require("lde-test")
local fs = require("fs")
local wonderland = require("wonderland")
local element = require("wonderland.element")
local style = require("wonderland.style")
local paths = require("beat.paths")
local Settings = require("beat.app.services.settings")
local Motion = require("beat.app.services.motion")
local Appearance = require("beat.app.services.appearance")
local settingsList = require("beat.app.components.settings_list")

local configDirectory = os.tmpname() .. "-beat-settings-list-config"
os.remove(configDirectory)
fs.mkdirAll(configDirectory)

local realDirectory = paths.directory
paths.directory = function() return configDirectory end

test.afterAll(function()
	paths.directory = realDirectory
	fs.rmdir(configDirectory)
end)

--- An app with the real theme service, which is all a row's styles are built from.
---@return beat.App
local function app()
	local settings = Settings.new()
	local motion = Motion.new({ settings = settings })
	motion.clock.reduce = false
	return { services = { appearance = Appearance.new({ settings = settings, motion = motion }) } } --[[@as beat.App]]
end

---@param parent wonderland.Element
---@param at number
---@return wonderland.Element
local function childAt(parent, at)
	local child = element.at(parent.childFirst)
	for _ = 2, at do child = element.at(child.nextSibling) end
	return child
end

---@param el wonderland.Element
---@return wonderland.StyleSlot
local function styleOf(el)
	return style.at(el.baseStyle)
end

test.it("a clickable row's hover covers the padding the row owns", function()
	element.beginFrame()
	local instance = app()
	local theme = instance.services.appearance.theme
	local width = theme:px(400)
	local item = settingsList.row(instance, { label = "Plugins", width = width, onClick = { type = "x" } })
	local base = styleOf(item.element)
	local hover = style.at(item.element.hoverStyle)

	test.equal(base.widthUnit, style.REL, "the row fills the card")
	test.equal(base.wantWidth, 1.0, "without a width of its own")
	test.equal(base.paddingLeft, theme:px(16), "its own left inset")
	test.equal(base.paddingRight, theme:px(16), "and right inset")
	test.equal(base.heightUnit, style.ABS, "the row height is the shape's")
	test.equal(base.wantHeight, item.height, "and is exactly that")
	test.equal(base.radius, theme:radius("md"), "the highlight meets the card's rounded corners")

	test.equal(hover.paddingLeft, theme:px(16), "the hover box keeps the same left inset")
	test.equal(hover.paddingRight, theme:px(16), "and right inset")
	test.truthy(hover.paint ~= 0, "the hover box is filled")
	test.truthy(hover.bgA > 0, "with a visible colour")

	local content = childAt(item.element, 1)
	test.equal(styleOf(content).wantWidth, width - theme:px(34), "content fits inside the padding")
end)

test.it("a plain row reserves the same inset", function()
	element.beginFrame()
	local theme = app().services.appearance.theme
	local item = settingsList.row(app(), { label = "Theme", width = theme:px(400) })
	local base = styleOf(item.element)

	test.equal(base.widthUnit, style.REL, "the row fills the card")
	test.equal(base.paddingLeft, theme:px(16), "with the clickable row's left inset")
	test.equal(base.paddingRight, theme:px(16), "and the same right inset")
end)

test.it("the card leaves the horizontal padding to its rows", function()
	element.beginFrame()
	local theme = app().services.appearance.theme
	local width = theme:px(400)
	local first = settingsList.row(app(), { label = "One", width = width })
	local second = settingsList.row(app(), { label = "Two", width = width })
	local card = settingsList.group(app(), { title = "Group", rows = { first, second }, width = width })

	local group = childAt(card, 2)
	local box = styleOf(group)
	test.equal(box.paddingLeft, 0, "the card has no inset of its own")
	test.equal(box.paddingRight, 0, "on either side")
	test.equal(box.radius, theme:radius("md"), "and keeps its rounded corners")

	local separator = childAt(group, 2)
	local line = styleOf(separator)
	test.equal(line.widthUnit, style.REL, "the hairline takes the card's width")
	test.equal(line.marginLeft, theme:px(16), "stopping short of the left edge")
	test.equal(line.marginRight, theme:px(16), "and the right one")
end)

-- The sidebar width choice: the page writes which option is chosen into the option list the
-- segmented control reads. A width is only chosen while the sidebar is open, and while it is
-- collapsed the Collapse option is the one chosen; exactly one option is the accent in every state.
-- The page is built here rather than the option list being rebuilt by the test, so the mapping the
-- bug lived in is the one under test.
test.it("marks exactly the sidebar width option in force as chosen", function()
	local App = require("beat.app")
	local page = require("beat.app.pages.settings")
	App:init({ scan = false })
	local values = App.services.settings.values
	local window = { width = 1200, height = 720 }
	local labels = { ["Narrow"] = true, ["Balanced"] = true, ["Wide"] = true, ["Collapse"] = true }
	local cases = {
		{ width = 220, collapsed = false, chosen = "Narrow" },
		{ width = 264, collapsed = false, chosen = "Balanced" },
		{ width = 320, collapsed = false, chosen = "Wide" },
		-- Collapsing keeps the width for the next expansion: the width option must not stay lit.
		{ width = 264, collapsed = true, chosen = "Collapse" },
		{ width = 220, collapsed = true, chosen = "Collapse" }
	}

	for _, case in ipairs(cases) do
		values.sidebarWidth, values.sidebarCollapsed = case.width, case.collapsed
		element.beginFrame()
		local root = page.view(App, { kind = "settings" }, window)
		local seen, active, activeCount = {}, {}, 0
		local function walk(node, parent)
			local label = element.textOf(node)
			if label ~= nil and labels[label] then
				seen[label] = true
				-- The chosen option's cell is filled in the accent; the others are transparent.
				if parent ~= nil and style.at(parent.baseStyle).bgA > 0 then
					active[label] = true
					activeCount += 1
				end
			end
			local child = node.childFirst
			while child ~= 0 do
				local next = element.at(child)
				walk(next, node)
				child = next.nextSibling
			end
		end
		walk(root, nil)

		for label in pairs(labels) do
			test.truthy(seen[label], "the " .. label .. " option is on the page")
		end
		test.equal(activeCount, 1, "one option is the accent when collapsed is " .. tostring(case.collapsed))
		test.truthy(active[case.chosen], case.chosen .. " is the chosen option")
	end
	App.services.playback.player:close()
end)
