-- Something a service announces after it has happened: the library was replaced, tags changed.
-- Only services listen, and only to services they were given, so who can hear what is decided by
-- what each service says it needs. Listeners are called in the order they connected, which is the
-- order the services were made in: a service always hears after everything it depends on.
---@class beat.Signal
---@field listeners fun(value: any)[]
local Signal = {}
Signal.__index = Signal

---@return beat.Signal
function Signal.new()
	return setmetatable({ listeners = {} }, Signal)
end

--- There is no disconnect: services are made together and dropped together, so a listener never
--- outlives what it listens to.
---@param listener function
function Signal:connect(listener)
	self.listeners[#self.listeners + 1] = listener
end

--- Fired once the change is complete, so a listener sees the state it is being told about. One
--- value goes with it, and a listener that wants none ignores it: forwarding a vararg cannot be
--- compiled, and a service fires on the frames its state changes.
---@param value any
function Signal:fire(value)
	for index = 1, #self.listeners do self.listeners[index](value) end
end

return Signal
