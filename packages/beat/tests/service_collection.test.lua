local test = require("lde-test")
local ServiceCollection = require("beat.app.service_collection")
local Signal = require("beat.app.signal")

--- What these test services keep: the collection gives each one its deps, and the test reads them
--- back through this field.
---@class TestServiceInstance: beat.ServiceInstance
---@field deps table<string, any>

--- A service that records when it was made and keeps what it was given.
---@param needs string[]?
---@param handles string[]?
---@param made TestServiceInstance[]?
---@return beat.Service
local function service(needs, handles, made)
	---@param deps table<string, any>
	---@return TestServiceInstance
	local function new(deps)
		local instance = { deps = deps}
		if made ~= nil then made[#made + 1] = instance end
		return instance
	end
	return {
		needs = needs,
		handles = handles,
		new = new,
	}
end

test.it("makes every service after what it needs, whatever order they were added in", function()
	---@type TestServiceInstance[]
	local made = {}
	local collection = ServiceCollection.new()
	collection:add("scan", service({ "library", "playback"}, nil, made))
	collection:add("playback", service({ "settings"}, nil, made))
	collection:add("library", service({ "settings"}, nil, made))
	collection:add("settings", service({}, nil, made))
	local services = collection:build()

	local at = {}
	for index, instance in ipairs(services.order) do at[instance] = index end
	test.truthy(at[services.byName.settings] < at[services.byName.library])
	test.truthy(at[services.byName.settings] < at[services.byName.playback])
	test.truthy(at[services.byName.library] < at[services.byName.scan])
	test.truthy(at[services.byName.playback] < at[services.byName.scan])
	test.equal(#made, 4, "each is made once, however many need it")
	---@type TestServiceInstance
	local scan = services.byName.scan
	test.equal(scan.deps.library, services.byName.library, "it is given the instance")
end)

test.it("gives a service what was provided in place of a service", function()
	local collection = ServiceCollection.new()
	local emit = function() end
	local standIn = { stand = "in"}
	collection:add("search", service({ "library", "emit"}))
	collection:provide("library", standIn)
	collection:provide("emit", emit)
	---@type TestServiceInstance
	local search = collection:build().byName.search

	test.equal(search.deps.library, standIn)
	test.equal(search.deps.emit, emit)
end)

test.it("stops at a dependency nobody added", function()
	local collection = ServiceCollection.new()
	collection:add("search", service({ "library"}))
	local ok, err = pcall(function() collection:build() end)

	test.falsy(ok)
	test.truthy(tostring(err):find("search needs library", 1, true))
end)

test.it("stops at services that need each other in a circle", function()
	local collection = ServiceCollection.new()
	collection:add("a", service({ "b"}))
	collection:add("b", service({ "c"}))
	collection:add("c", service({ "a"}))
	local ok, err = pcall(function() collection:build() end)

	test.falsy(ok)
	test.truthy(tostring(err):find("a -> b -> c -> a", 1, true))
end)

test.it("stops a service using something it did not list", function()
	local collection = ServiceCollection.new()
	collection:add("settings", service({}))
	collection:add("search", {
		needs = {},
		new = function(deps) return { settings = deps.settings} end,
	})
	local ok, err = pcall(function() collection:build() end)

	test.falsy(ok)
	test.truthy(tostring(err):find("search uses settings but does not list it in needs", 1, true))
end)

test.it("gives each message type one owner", function()
	local collection = ServiceCollection.new()
	collection:add("search", service({}, { "search", "clearSearch"}))
	collection:add("playback", service({}, { "togglePlay"}))
	local services = collection:build()
	test.equal(services.owners.clearSearch, services.byName.search)
	test.equal(services.owners.togglePlay, services.byName.playback)

	local clash = ServiceCollection.new()
	clash:add("search", service({}, { "clearSearch"}))
	clash:add("library", service({}, { "clearSearch"}))
	local ok, err = pcall(function() clash:build() end)
	test.falsy(ok)
	test.truthy(tostring(err):find("clearSearch is handled by two services", 1, true))
end)

test.it("calls a signal's listeners in the order they connected", function()
	local signal = Signal.new()
	local heard = {}
	signal:connect(function(value) heard[#heard + 1] = "first " .. value end)
	signal:connect(function(value) heard[#heard + 1] = "second " .. value end)
	signal:fire("x")

	test.equal(heard[1], "first x")
	test.equal(heard[2], "second x")
end)
