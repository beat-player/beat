-- Long-running work a plugin or a built-in service can report: a download, a sync, anything that
-- has a beginning and an end but must not take the screen. The service keeps the list the top bar
-- and its panel draw; the owner keeps the work and says how far it has got. Cancelling is a message
-- too, so the task's owner hears it where it already handles messages rather than through a second
-- callback.
local wonderland = require("wonderland")

local time = wonderland.time

-- A task that ended stays long enough to be read, then goes. A failure is the exception: it names
-- something the person has to know about, so it is dismissed by hand.
local LINGER = 5

---@class beat.Task
---@field id number
---@field title string
---@field detail string?
---@field progress number? # How far it has got, 0..1; nil is indeterminate
---@field cancel beat.Message? # What the owner hears when this task is cancelled
---@field state "running"|"cancelling"|"done"|"failed"|"cancelled"
---@field startedAt number
---@field endedAt number? # When it reached done, failed or cancelled
---@field service beat.TasksService
local Task = {}
Task.__index = Task

---@class beat.TaskDefinition
---@field title string
---@field detail string?
---@field progress number? # 0..1; nil is indeterminate
---@field cancel beat.Message?

---@param value any
local function fraction(value)
	if type(value) ~= "number" or value ~= value then return nil end
	return math.max(0, math.min(1, value))
end

--- Calls made by the owner rather than by a message still have to reach a frame: the service's
--- `step` is where that is noticed.
function Task:touch()
	self.service:changed()
end

---@param fields { title: string?, detail: string?, progress: number? }
---@return beat.Task
function Task:update(fields)
	if self.state ~= "running" and self.state ~= "cancelling" then return self end
	if fields.title ~= nil then self.title = fields.title end
	if fields.detail ~= nil then self.detail = fields.detail end
	if fields.progress ~= nil then self.progress = fraction(fields.progress) end
	self:touch()
	return self
end

--- The work is over and worked. The detail is what the task did, when it has something to say.
---@param detail string?
---@return beat.Task
function Task:finish(detail)
	self.state = "done"
	self.progress = 1
	if detail ~= nil then self.detail = detail end
	self.endedAt = time.now()
	self:touch()
	return self
end

--- The work did not finish. `err` is why, and is what the panel shows until it is dismissed.
---@param err string
---@return beat.Task
function Task:fail(err)
	self.state = "failed"
	self.detail = err
	self.endedAt = time.now()
	self:touch()
	return self
end

--- The owner answered a cancel: the work stopped because it was asked to, not because it failed.
---@return beat.Task
function Task:cancelled()
	self.state = "cancelled"
	self.endedAt = time.now()
	self:touch()
	return self
end

---@class beat.TasksService: beat.Service
---@field list beat.Task[]
---@field nextId number
---@field dirty boolean
---@field emit fun(message: beat.Message)
local Tasks = {}
Tasks.__index = Tasks
Tasks.needs = { "emit" }

---@param deps { emit: fun(message: beat.Message) }
---@return beat.TasksService
function Tasks.new(deps)
	return setmetatable({ list = {}, nextId = 0, dirty = false, emit = deps.emit }, Tasks)
end

--- Something changed outside a message: the next tick is what puts it on screen.
function Tasks:changed()
	self.dirty = true
end

--- The tasks that have not gone yet, oldest first.
---@return beat.Task[]
function Tasks:tasks()
	return self.list
end

---@param id number
---@return beat.Task?
function Tasks:find(id)
	for _, task in ipairs(self.list) do
		if task.id == id then return task end
	end
	return nil
end

--- Starts a task and returns its handle. The owner keeps the handle and says how the work goes;
--- the service keeps the copy the panel draws and hands to `taskCancel`.
---@param definition beat.TaskDefinition
---@return beat.Task
function Tasks:start(definition)
	if type(definition.title) ~= "string" or definition.title == "" then
		error("a task needs a title", 2)
	end
	if definition.detail ~= nil and type(definition.detail) ~= "string" then
		error("a task's detail must be a string", 2)
	end
	if definition.cancel ~= nil and type(definition.cancel) ~= "table" then
		error("a task's cancel must be a message", 2)
	end

	self.nextId += 1
	---@type beat.Task
	local task = setmetatable({
		id = self.nextId,
		title = definition.title,
		detail = definition.detail,
		progress = fraction(definition.progress),
		cancel = definition.cancel,
		state = "running",
		startedAt = time.now(),
		endedAt = nil,
		service = self
	}, Task)
	self.list[#self.list + 1] = task
	self:changed()
	return task
end

Tasks.on = {
	---@param self beat.TasksService
	---@param message beat.TaskCancelMessage
	taskCancel = function(self, message)
		local task = self:find(message.id)
		-- A task without a cancel message cannot be asked to stop: the panel shows no button and
		-- a stray message must not leave it "cancelling" for ever.
		if task ~= nil and task.state == "running" and task.cancel ~= nil then
			task.state = "cancelling"
			self:changed()
			self.emit(task.cancel)
		end
	end,

	---@param self beat.TasksService
	---@param message beat.TaskDismissMessage
	taskDismiss = function(self, message)
		local task = self:find(message.id)
		if task ~= nil and task.state == "failed" then
			for at, candidate in ipairs(self.list) do
				if candidate == task then
					table.remove(self.list, at)
					break
				end
			end
			self:changed()
		end
	end
}

--- Done and cancelled tasks leave after `LINGER`; failed ones wait for a dismiss. A running task
--- keeps the app awake so an indeterminate bar moves and `task:update` from the owner's own step
--- is drawn.
---@param now number
---@return boolean changed
---@return boolean busy
function Tasks:step(now)
	local changed = self.dirty
	self.dirty = false

	-- Only a task that is due to go makes a new list: a step while anything is running happens
	-- every frame, and most of them have nothing to remove.
	---@type beat.Task[]?
	local kept
	for at, task in ipairs(self.list) do
		local ended = task.state == "done" or task.state == "cancelled"
		if ended and task.endedAt ~= nil and now >= task.endedAt + LINGER then
			if kept == nil then
				kept = {}
				for before = 1, at - 1 do kept[before] = self.list[before] end
			end
			changed = true
		elseif kept ~= nil then
			kept[#kept + 1] = task
		end
	end
	if kept ~= nil then self.list = kept end

	local busy = false
	for _, task in ipairs(self.list) do
		if task.state == "running" or task.state == "cancelling" then
			busy = true
			break
		end
	end
	return changed, busy
end

return Tasks
