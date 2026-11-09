-- The tasks service without a window: what a task's lifetime is, what cancelling delivers, and
-- what a failure waits for. The panel and the top bar read the same list this exercises.
local test = require("lde-test")
local wonderland = require("wonderland")
local messages = require("beat.message")
local Tasks = require("beat.app.services.tasks")

local time = wonderland.time

---@return beat.TasksService
---@return beat.Message[]
local function service()
	---@type beat.Message[]
	local emitted = {}
	---@param message beat.Message
	local function emit(message) emitted[#emitted + 1] = message end
	return Tasks.new({ emit = emit }), emitted
end

test.it("starts, updates and finishes a task, then lets it go", function()
	local tasks = service()
	local task = tasks:start({ title = "Downloading", detail = "Starting", progress = 0.1 })

	test.equal(task.id, 1)
	test.equal(task.state, "running")
	test.equal(task.title, "Downloading")
	test.equal(task.detail, "Starting")
	test.equal(task.progress, 0.1)
	test.equal(#tasks:tasks(), 1)

	local changed, busy = tasks:step(time.now())
	test.truthy(changed, "a new task is a change")
	test.truthy(busy, "a running task keeps the app awake")

	task:update({ title = "Downloading album", detail = "2 of 5", progress = 0.4 })
	test.equal(task.title, "Downloading album")
	test.equal(task.detail, "2 of 5")
	test.equal(task.progress, 0.4)

	task:finish("Five tracks")
	test.equal(task.state, "done")
	test.equal(task.detail, "Five tracks")
	test.equal(task.progress, 1)

	local finishedAt = assert(task.endedAt)
	tasks:step(finishedAt + 4)
	test.equal(#tasks:tasks(), 1, "a finished task is readable for a moment")

	changed, busy = tasks:step(finishedAt + 5.1)
	test.truthy(changed)
	test.falsy(busy)
	test.equal(#tasks:tasks(), 0, "a finished task goes after its linger")
end)

test.it("marks a task cancelling, delivers its message, and accepts its own answer", function()
	local tasks, emitted = service()
	local stop = messages.custom("download:cancel", { id = 3 })
	local task = tasks:start({ title = "Downloading", cancel = stop })

	tasks:update(messages.taskCancel(task.id))
	test.equal(task.state, "cancelling")
	test.equal(#emitted, 1, "the owner heard once")
	test.equal(emitted[1], stop, "the owner heard the message the task named")

	task:cancelled()
	test.equal(task.state, "cancelled")
	tasks:update(messages.taskCancel(task.id))
	test.equal(#emitted, 1, "a task already cancelling is not asked twice")

	local endedAt = assert(task.endedAt)
	tasks:step(endedAt + 6)
	test.equal(#tasks:tasks(), 0, "a cancelled task goes after its linger")
end)

test.it("leaves a task without a cancel message alone", function()
	local tasks, emitted = service()
	local task = tasks:start({ title = "Cannot stop" })

	tasks:update(messages.taskCancel(task.id))
	test.equal(task.state, "running", "there is nothing to deliver, so nothing is marked")
	test.equal(#emitted, 0)
end)

test.it("keeps a failed task until it is dismissed", function()
	local tasks = service()
	local task = tasks:start({ title = "Downloading" })
	task:fail("Connection refused")

	test.equal(task.state, "failed")
	test.equal(task.detail, "Connection refused")
	tasks:step(time.now() + 1000)
	test.equal(#tasks:tasks(), 1, "a failure waits for the person")

	tasks:update(messages.taskDismiss(task.id))
	test.equal(#tasks:tasks(), 0, "dismissing takes it away")

	local running = tasks:start({ title = "Still running" })
	tasks:update(messages.taskDismiss(running.id))
	test.equal(#tasks:tasks(), 1, "a running task is not dismissed by a stray message")
end)

test.it("treats a progress outside nothing-to-one as the end it is nearest", function()
	local tasks = service()
	local task = tasks:start({ title = "Working", progress = 2 })
	test.equal(task.progress, 1)
	task:update({ progress = -1 })
	test.equal(task.progress, 0)
end)
