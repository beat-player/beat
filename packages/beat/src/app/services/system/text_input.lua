-- The phone's on-screen keyboard, as a field wonderland draws can take it.
--
-- A NativeActivity has no editor to give an input method, so the keyboard is shown without an
-- InputConnection: what it types arrives as key events, and glide typing, suggestions and
-- composing -- which need a connection -- are not offered at all. The Java class
-- (android/beat/TextInput.java) adds an invisible editor to the activity and takes the keyboard
-- there; this service is what applies what it typed to the field actually on screen.
--
-- The Java editor is the authority while the keyboard has a field: its text mirror is what the
-- keyboard reads for suggestions, and every edit it makes arrives here as a byte range of the
-- value with the text that replaced it. The field is edited through wonderland's `Layout:edit`,
-- so it answers its `oninput` exactly as a key's edit does, and the app hears the same message.
-- When the field changes by any other way -- a clear mark, a caret placed by a tap, a page
-- changed under it -- the value and caret are pushed back to the mirror with `sync`.
--
-- Nothing here runs off Android, and a bridge that cannot be loaded leaves the window's own
-- keyboard path alone: `setTextInputHandler` is installed only once the editor is there.
local platform = require("beat.platform")
local wonderland = require("wonderland")
local dex = require("beat.app.services.system.dex")

local time = wonderland.time

-- How many keyboard edits one tick takes. A glide sends a composing update as the finger moves,
-- so there can be several a frame; the rest wait for the next one rather than holding the frame.
local MAX_EVENTS = 32

-- How often the keyboard's queue is read while a field has it. The update a glide sends is what
-- the field shows, and a word composing at thirty updates a second is smooth to read; reading it
-- sixty times is a Java call and a local frame per display frame for no more than that.
local POLL_INTERVAL = 1 / 30

-- How often it is read once nothing has arrived for a second. A field that has the keyboard but
-- is not being typed into -- a search box left focused, the phone in a hand -- should not wake the
-- app at the display's rate for a JNI call that answers nothing. A composing word keeps sending
-- updates, and each one puts the fast pace back, so a word being typed is read as before.
local QUIET_INTERVAL = 0.25
local ACTIVE_WINDOW = 1

-- EditorInfo.IME_ACTION_SEARCH and IME_ACTION_DONE: the keyboard's action key.
local IME_ACTION_SEARCH = 3
local IME_ACTION_DONE = 6

-- The bridge the process loaded, kept across the app being set up again: a second editor view
-- would be a second view in the activity, and only one of them can have the keyboard.
---@type beat.TextInputBridge?
local shared = nil

---@class beat.TextInputBridge
---@field instance ffi.cdata*
---@field jni beat.DexJni
---@field entry string? # What the last poll took, so the frame closure is made once
---@field pollInFrame fun()
local Bridge = {}
Bridge.__index = Bridge

---@param jni beat.DexJni
---@param instance ffi.cdata*
---@return beat.TextInputBridge
local function newBridge(jni, instance)
	local bridge = setmetatable({ instance = instance, jni = jni, entry = nil }, Bridge)

	-- The poll runs every frame a field is focused, and the frame it runs in is a JNI local
	-- frame: the closure is one made here rather than one per poll, so an idle keyboard costs no
	-- Lua memory.
	bridge.pollInFrame = function()
		local value = jni.call(instance, "java/util/function/Supplier", "get", "()Ljava/lang/Object;", "object")
		if value ~= nil then bridge.entry = jni.tostring(value) end
	end

	return bridge
end

--- What the keyboard did since the last poll, or nil: an `r`, `k`, `a` or `p` command.
---@return string?
function Bridge:poll()
	self.entry = nil
	local _, err = self.jni.frame(self.pollInFrame, 4)
	if err ~= nil then
		self.entry = nil
		require("beat.log").write("warn", "text input poll failed: " .. tostring(err))
	end
	return self.entry
end

--- Tell the editor what the field holds, and where its caret is.
---@param text string
---@param cursor number # A byte of `text`
---@return boolean
function Bridge:sync(text, cursor)
	local jni = self.jni
	local _, err = jni.frame(function()
		jni.call(
			self.instance,
			"java/util/function/Consumer",
			"accept",
			"(Ljava/lang/Object;)V",
			"void",
			jni.string("c" .. cursor .. ":" .. text)
		)
	end, 4)
	if err ~= nil then
		require("beat.log").write("warn", "text input sync failed: " .. tostring(err))
		return false
	end
	return true
end

--- Show the keyboard over the field, with what it holds and the action its key sends.
---@param text string
---@param cursor number
---@param action number # EditorInfo.IME_ACTION_*
---@return boolean
function Bridge:show(text, cursor, action)
	local jni = self.jni
	local _, err = jni.frame(function()
		jni.call(
			self.instance,
			"java/util/function/Consumer",
			"accept",
			"(Ljava/lang/Object;)V",
			"void",
			jni.string("s" .. action .. ":" .. cursor .. ":" .. text)
		)
	end, 4)
	if err ~= nil then
		require("beat.log").write("warn", "text input show failed: " .. tostring(err))
		return false
	end
	return true
end

--- Let the keyboard go, and forget what it did for the field it was on.
function Bridge:hide()
	local jni = self.jni
	local _, err = jni.frame(function()
		jni.call(
			self.instance,
			"java/util/function/Consumer",
			"accept",
			"(Ljava/lang/Object;)V",
			"void",
			jni.string("h")
		)
	end, 4)
	if err ~= nil then require("beat.log").write("warn", "text input hide failed: " .. tostring(err)) end
end

--- Load TextInput out of the app's dex and attach the activity to it.
---@return beat.TextInputBridge?, string?
local function loadBridge()
	---@diagnostic disable-next-line: missing-module
	local android = require("androidapi") --[[@as beat.AndroidApi]]
	local jni = android.jni
	local activity = assert(android.activity())
	local instance, err = jni.frame(function()
		local class = dex.class(jni, activity, "beat.TextInput")
		local made = jni.call(class, "java/lang/Class", "newInstance", "()Ljava/lang/Object;", "object")
		jni.call(made, "java/util/function/Consumer", "accept", "(Ljava/lang/Object;)V", "void", activity.clazz)
		return jni.global(made)
	end, 8)
	if instance == nil then return nil, err or "TextInput did not load" end
	return newBridge(jni, instance)
end

--- What a keyboard command means, as a table: one range to replace, one key, one action, or
--- where the keyboard put the caret.
---@class beat.TextInputEvent
---@field kind "replace"|"key"|"action"|"caret"
---@field from number? # replace: the first byte of the field's value it takes away
---@field to number? # and the byte after the last
---@field cursor number? # replace, caret: the byte the caret is left before
---@field text string? # replace: what goes in place of the range
---@field key string? # key: wonderland's name for it
---@field action number? # action: EditorInfo.IME_ACTION_*

---@class beat.TextInputService: beat.Service
---@field app beat.App
---@field window fun(): wonderland.RenderWindow?
---@field emit fun(message: any)
---@field bridge beat.TextInputBridge?
---@field failed boolean # The editor could not be made; the window's own keyboard is left alone
---@field shown boolean # Whether the keyboard is up over a field
---@field field string? # The field it is up over
---@field expected string? # What the Java mirror holds, which is what a mismatch means an edit by something else
---@field expectedCursor number?
---@field activeUntil number? # When the last keyboard activity stops asking for the fast poll
local TextInput = {}
TextInput.__index = TextInput
TextInput.needs = { "app", "window", "emit" }

---@param deps { app: beat.App, window: fun(): wonderland.RenderWindow?, emit: fun(message: any) }
---@return beat.TextInputService
function TextInput.new(deps)
	return setmetatable({
		app = deps.app,
		window = deps.window,
		emit = deps.emit,
		bridge = nil,
		failed = false,
		shown = false,
		field = nil,
		expected = nil,
		expectedCursor = nil,
		activeUntil = nil
	}, TextInput)
end

--- Load the editor and take the window's keyboard over. The window's own path is only replaced
--- once there is an editor to replace it with.
---@param window wonderland.RenderWindow
---@return boolean
function TextInput:start(window)
	local layout = self.app.layoutPlugin
	if layout == nil or layout.getInput == nil or layout.edit == nil then
		self.failed = true
		require("beat.log").write("warn", "no on-screen text input: wonderland has no field editor")
		return false
	end
	if window.setTextInputHandler == nil then
		self.failed = true
		require("beat.log").write("warn", "no on-screen text input: the window has no keyboard to take over")
		return false
	end
	if self.bridge == nil then
		if shared == nil then
			local bridge, err = loadBridge()
			if bridge == nil then
				self.failed = true
				require("beat.log").write("warn", "no on-screen text input: " .. tostring(err))
				return false
			end
			shared = bridge
		end
		self.bridge = shared
	end

	-- The window asks before showing or hiding its own keyboard: the editor is the keyboard's
	-- business while a field has it, and nothing at all until one does. Showing it here rather
	-- than waiting for the next step is what makes a tapped field put the keyboard up at once;
	-- the step is what takes what it types afterwards.
	window:setTextInputHandler(function(enabled)
		if self.bridge == nil then return false end
		if enabled then
			self:showFocused(window)
			-- The ticker is what polls the keyboard, and it may be asleep for the idle interval:
			-- a field that just took the keyboard is a reason to wake it now.
			if self.app.wake ~= nil then self.app:wake() end
		else
			self:hide()
		end
		return true
	end)
	return true
end

--- Show the keyboard over whichever field has the focus now, with what it holds. The value is
--- read at the moment the window asks, so a tap that focuses a field and a page that opens with
--- one both arrive here with the right text. Whether a field was there is answered, because a
--- press that left every field has nothing to show and no reason to wake the ticker.
---@param window wonderland.RenderWindow
---@return boolean
function TextInput:showFocused(window)
	local layout = self.app.layoutPlugin
	if layout == nil or layout.getInput == nil then return false end
	local value, cursor = layout:getInput(window)
	if value == nil then return false end
	self:show(value, cursor, layout:getFocusedId(window))
	return true
end

--- A press anywhere in the window. A field that is already focused and whose keyboard was
--- dismissed -- the keyboard's own back arrow does that without moving the focus -- is not a
--- focus change the window hears about, so the press is what asks for it again. A press that
--- leaves the field has already cleared the focus by the time this runs, and does nothing.
function TextInput:tap()
	if not platform.android or self.failed or self.bridge == nil then return end
	local window = self.window()
	if window == nil then return end
	if self:showFocused(window) and self.app.wake ~= nil then self.app:wake() end
end

--- Show the keyboard over the field `field`, with what it holds and where its caret is.
---@param value string
---@param cursor number
---@param field string?
function TextInput:show(value, cursor, field)
	if self.bridge == nil then return end
	local action = field ~= nil and field:lower():find("search", 1, true) and IME_ACTION_SEARCH or IME_ACTION_DONE
	self.bridge:show(value, cursor, action)
	self.shown, self.field = true, field
	self.expected, self.expectedCursor = value, cursor
	-- A field that just took the keyboard is the next place a person will type: keep the fast
	-- poll for a second so the first word is not read a quarter second late.
	self.activeUntil = time.now() + ACTIVE_WINDOW
end

function TextInput:hide()
	if self.bridge ~= nil and self.shown then self.bridge:hide() end
	self.shown, self.field, self.expected, self.expectedCursor = false, nil, nil, nil
	self.activeUntil = nil
end

--- Turn one queued command into the edit it describes. A message the field's `oninput` answered
--- is emitted, so the app hears a keyboard's edit the way it hears a key's.
---@param entry string
---@param layout wonderland.plugin.Layout?
---@param window wonderland.RenderWindow?
---@return boolean # Whether the command was one this understood
function TextInput:apply(entry, layout, window)
	local event = TextInput.decode(entry)
	if event == nil or layout == nil or window == nil then return false end

	local message
	if event.kind == "replace" then
		message = layout:edit(window, event.from, event.to, event.text, event.cursor)
	elseif event.kind == "key" then
		message = layout:key(window, event.key)
		-- A key is not a range, so the Java mirror did not see what it did: a return in a
		-- paragraph puts a line in the field, and the next composing update must start from that.
		if self.bridge ~= nil then
			local value, cursor = layout:getInput(window)
			if value ~= nil then
				self.bridge:sync(value, cursor)
				self.expected, self.expectedCursor = value, cursor
			end
		end
	elseif event.kind == "action" then
		-- What the keyboard's action key means to a field is its return: a field of one line
		-- sends what it holds, which is the search's whole behaviour.
		message = layout:key(window, "return")
		if self.bridge ~= nil then
			local value, cursor = layout:getInput(window)
			if value ~= nil then
				self.bridge:sync(value, cursor)
				self.expected, self.expectedCursor = value, cursor
			end
		end
	elseif event.kind == "caret" then
		local _, cursor = layout:getInput(window)
		if cursor ~= nil then message = layout:edit(window, cursor, cursor, "", event.cursor) end
	end

	if message ~= nil then self.emit(message) end
	return true
end

--- Take what the keyboard queued and apply it. Up to `MAX_EVENTS` a tick, so a glide that sent
--- many composing updates does not hold a frame.
---@return number count
function TextInput:drain()
	if self.bridge == nil then return 0 end

	local window = self.window()
	local layout = self.app.layoutPlugin
	local count = 0

	while count < MAX_EVENTS do
		local entry = self.bridge:poll()
		if entry == nil then break end
		count += 1
		self:apply(entry, layout, window)
	end

	-- The edits applied here are the ones the mirror already made, so they agree; what does not
	-- agree is a field changed by something else, which `step` syncs on the next pass.
	if count > 0 and window ~= nil and layout ~= nil then
		local value, cursor = layout:getInput(window)
		if value ~= nil then self.expected, self.expectedCursor = value, cursor end

		-- The field is drawn from the app's state, so what the keyboard typed is only on screen
		-- after the frame is built again: the same frame a key press asks for, at the display's
		-- rate rather than a frame per composing update.
		local ui = self.app.uiPlugin
		if ui ~= nil and ui.requestRedraw ~= nil then
			ui:requestRedraw(window, true)
		elseif self.app.refresh ~= nil then
			self.app:refresh()
		end
	end

	return count
end

---@param entry string
---@return beat.TextInputEvent?
function TextInput.decode(entry)
	if type(entry) ~= "string" or entry == "" then return nil end

	local kind = entry:sub(1, 1)

	if kind == "r" then
		local from, to, cursor, text = entry:match("^r(%d+),(%d+),(%d+):(.*)$")
		if from == nil then return nil end
		return { kind = "replace", from = tonumber(from), to = tonumber(to), cursor = tonumber(cursor), text = text }
	elseif kind == "k" then
		local key = entry:sub(2)
		if key == "" then return nil end
		return { kind = "key", key = key }
	elseif kind == "a" then
		local action = tonumber(entry:sub(2))
		if action == nil then return nil end
		return { kind = "action", action = action }
	elseif kind == "p" then
		local cursor = tonumber(entry:sub(2))
		if cursor == nil then return nil end
		return { kind = "caret", cursor = cursor }
	end

	return nil
end

--- How long until the keyboard's queue should be read again: the fast pace while a word is being
--- typed, the quiet one once the field has been still for a second.
---@param self beat.TextInputService
---@param now number
---@return number
local function pollInterval(self, now)
	local untilAt = self.activeUntil
	if untilAt ~= nil and now < untilAt then return POLL_INTERVAL end
	return QUIET_INTERVAL
end

--- The keyboard follows the field, and what was typed is taken while it has one: a window with
--- no field asks for no ticks, which is a phone that is not being typed into.
---@param now number
---@return boolean changed
---@return boolean|number busy
function TextInput:step(now)
	if not platform.android or self.failed then return false, false end

	local window = self.window()
	if window == nil then return false, false end
	if self.bridge == nil and not self:start(window) then return false, false end

	local layout = self.app.layoutPlugin
	local value, cursor
	local field

	if window.visible ~= false and layout ~= nil then
		value, cursor = layout:getInput(window)
		field = layout:getFocusedId(window)
	end

	if value == nil then
		if self.shown then self:hide() end
		return false, false
	end

	if not self.shown then
		self:show(value, cursor, field)
		return false, pollInterval(self, now)
	end

	-- Focus moved to another field while the keyboard stayed up: its text is what the mirror
	-- must hold, even where the window was not told the keyboard changed hands.
	if field ~= self.field then
		self:show(value, cursor, field)
		return false, pollInterval(self, now)
	end

	-- The field changed without the keyboard: a clear mark, a tap that moved the caret, a page
	-- change. The keyboard's mirror is told before its next edit, so composing stays over the
	-- word it is composing.
	if value ~= self.expected or cursor ~= self.expectedCursor then
		self.bridge:sync(value, cursor)
		self.expected, self.expectedCursor = value, cursor
	end

	if self:drain() > 0 then self.activeUntil = now + ACTIVE_WINDOW end
	return false, pollInterval(self, now)
end

--- The app is going or being set up again: the keyboard belongs to a field that is gone.
function TextInput:close()
	self:hide()
	self.bridge = nil
end

return TextInput
