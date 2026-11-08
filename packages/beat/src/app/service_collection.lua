-- Builds the app's services from what each one says it needs. The order they are made in, step
-- in and hear each other's signals in is worked out here and never written down by hand: a
-- service is made after everything it needs, and a mistake in what they declare stops the app at
-- start with a message saying which service and what.

---@class beat.Service: beat.ServiceInstance
---@field needs string[]? # Services, or provided values, this one is made with
---@field handles string[]? # The message types it answers; each type has one owner
---@field new fun(...): beat.ServiceInstance? # The instance: its state and its methods
---@field step (fun(self: beat.ServiceInstance, now: number): boolean?, boolean?)? # For a service that keeps none of its state on the instance
---@field update (fun(self: beat.ServiceInstance, message: beat.Message): boolean?)? # The same, for a module whose messages answer statically

--- What a service's `new` returns. Every field past the state is optional: a service takes only
--- the calls it has something to do for.
---@class beat.ServiceInstance
---@field step (fun(self: beat.ServiceInstance, now: number): boolean?, boolean?)? # Called every tick, after everything it needs
---@field update (fun(self: beat.ServiceInstance, message: beat.Message): boolean?)? # Called for the message types in `handles`
---@field flush (fun(self: beat.ServiceInstance))? # Writes anything deferred before the app goes
---@field close (fun(self: beat.ServiceInstance))? # The app is being set up again

---@class beat.ServiceCollection
---@field modules table<string, beat.Service>
---@field provided table<string, any>
local Collection = {}
Collection.__index = Collection

---@class beat.BuiltServices
---@field byName table<string, beat.ServiceInstance>
---@field order beat.ServiceInstance[] # Every service, each after everything it needs
---@field owners table<string, beat.ServiceInstance> # The service that answers each message type

---@return beat.ServiceCollection
function Collection.new()
	return setmetatable({ modules = {}, provided = {}}, Collection)
end

---@param name string
---@param module beat.Service
function Collection:add(name, module)
	assert(self.modules[name] == nil and self.provided[name] == nil, name .. " is added twice")
	self.modules[name] = module
end

--- Something that is not a service but can be needed like one: the app's `emit`, or a stand-in
--- in a test.
---@param name string
---@param value any
function Collection:provide(name, value)
	assert(self.modules[name] == nil and self.provided[name] == nil, name .. " is added twice")
	self.provided[name] = value
end

--- What a service is made with: exactly what it listed. Asking for anything else is an error
--- naming both, so `needs` cannot drift from what the code uses.
---@param name string
---@param needs string[]
---@param built table<string, any>
---@return table
local function depsFor(name, needs, built)
	local deps = {}
	for _, dependency in ipairs(needs) do deps[dependency] = built[dependency] end
	return setmetatable(deps, {
		__index = function(_, key)
			error(name .. " uses " .. tostring(key) .. " but does not list it in needs", 2)
		end,
	})
end

---@return beat.BuiltServices
function Collection:build()
	---@type table<string, any>
	local built = {}
	for name, value in pairs(self.provided) do built[name] = value end
	---@type table<string, "making"|"made">
	local state = {}
	local order = {}

	---@param name string
	---@param path string[]
	local function make(name, path)
		if state[name] == "made" or (self.provided[name] ~= nil) then return end
		if state[name] == "making" then
			error("services need each other in a circle: " .. table.concat(path, " -> ") .. " -> " .. name, 0)
		end
		local module = self.modules[name]
		if module == nil then
			error((path[#path] or "the app") .. " needs " .. name .. ", which is not a service or provided", 0)
		end

		state[name] = "making"
		path[#path + 1] = name
		for _, dependency in ipairs(module.needs or {}) do make(dependency, path) end
		path[#path] = nil

		built[name] = module.new(depsFor(name, module.needs or {}, built))
		order[#order + 1] = built[name]
		state[name] = "made"
	end

	-- By name, so the same services come out in the same order every time. Two services that do
	-- not need each other have no order anything may rely on.
	local names = {}
	for name in pairs(self.modules) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do make(name, {}) end

	local owners = {}
	for _, name in ipairs(names) do
		for _, kind in ipairs(self.modules[name].handles or {}) do
			if owners[kind] ~= nil then error(kind .. " is handled by two services", 0) end
			owners[kind] = built[name]
		end
	end

	local byName = {}
	for _, name in ipairs(names) do byName[name] = built[name] end
	return { byName = byName, order = order, owners = owners}
end

return Collection
