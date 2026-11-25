-- The app thread's half of the audio thread: two channels, the state each snapshot carries, and
-- commands that look like the treble.Player they replace.
--
-- `player.lua` drives this the way it drove treble when the player lived on the app's thread.
-- What changes is where the work is: `update` here only drains what the audio thread reported, and
-- the position it answers is the last snapshot moved on by the time since it arrived. That
-- interpolation is what lets the bar and the clocks run at the display's rate while the audio
-- thread reports thirty times a second.
local threading = require("threading")

--- One command or event on its way to or from the audio thread. Which fields mean something is
--- what `kind` says; both sides serialize it with string.buffer.
---@class beat.AudioMessage
---@field kind string
---@field id number?
---@field tracks beat.AudioTrack[]?
---@field track beat.AudioTrack?
---@field index number?
---@field startAt number?
---@field autoplay boolean?
---@field repeatOne boolean?
---@field seconds number?
---@field value number?
---@field bands treble.Equalizer.Band[]?
---@field device string?
---@field position number?
---@field duration number?
---@field playing boolean?
---@field completed boolean?
---@field last boolean? # Whether nothing is staged or repeated after the track that ended
---@field heard number?
---@field sampleRate number?
---@field written number?
---@field floor number?
---@field commandId number?
---@field message string?

---@class beat.AudioClient
---@field private commands threading.Channel
---@field private events threading.Channel
---@field private handle threading.Handle?
---@field private commandId number # Commands sent, so a snapshot can say what it already includes
---@field private stateId number # The last command that changed what the device does
---@field private appliedId number # The last command the audio thread says it applied
---@field private pendingTracks beat.AudioTrack[] # Tracks collected for the next load
---@field private pendingStartAt number
---@field private collecting boolean # Whether tracks are waiting for a load
---@field private closed boolean
---@field at number # The playhead the last snapshot reported
---@field trackDuration number
---@field playing boolean
---@field endedId number? # The command whose last track played out with nothing after it
---@field sampledAt number # `now` when the snapshot was applied
---@field heard number
---@field sampleRate number?
---@field written number?
---@field floor number?
---@field now number
---@field audioIndex number?
---@field loading boolean # Whether a requested track has yet to be heard
---@field loadingId number # The command that requested it
---@field released boolean # Whether the thread was only told to stop, never joined
---@field unjoined boolean # Whether a shutdown left the thread (and its channels) running
---@field dead boolean # Whether the audio thread ended without being asked
---@field error string?
---@field onTrackEnd fun(completed: boolean?)?
---@field onError fun(message: string)?
---@field onStarted fun(index: number)?
local AudioClient = {}
AudioClient.__index = AudioClient

-- Threads a shutdown could not wait for because their decoder was still in a read, and the
-- channels they read and write. A channel may only lose this side's reference once the thread has
-- attached to it -- a spawned function starts after this one returns -- or it could be freed just
-- as the thread reaches for it. The records are joined on a later start or shutdown once the
-- thread has finished; if the process ends first, the OS reclaims both.
---@class beat.ClosingClient
---@field handle threading.Handle
---@field commands threading.Channel
---@field events threading.Channel

---@class beat.AbandonedThreads
---@field records beat.ClosingClient[]
---@type beat.AbandonedThreads
local abandoned = { records = {} }

-- Only once the audio thread has joined: then no state on the other side can still be reaching for
-- the channels, and closing this side's reference is what frees them.
local function reap()
	local records = abandoned.records
	for at = #records, 1, -1 do
		local record = records[at]
		if record.handle:done() then
			pcall(record.handle.join, record.handle)
			record.commands:close()
			record.events:close()
			table.remove(records, at)
		end
	end
end

--- A client on channels already made, with the thread that answers them. `new` makes both; this
--- is what a test uses to stand a slow or scripted audio thread in place of the real one.
---@param commands threading.Channel
---@param events threading.Channel
---@param handle threading.Handle?
---@return beat.AudioClient
function AudioClient.attach(commands, events, handle)
	return setmetatable({
		commands = commands,
		events = events,
		handle = handle,
		commandId = 0,
		stateId = 0,
		appliedId = 0,
		pendingTracks = {},
		pendingStartAt = 0,
		collecting = true,
		closed = false,
		at = 0,
		trackDuration = 0,
		playing = false,
		endedId = nil,
		sampledAt = 0,
		heard = 0,
		sampleRate = nil,
		written = nil,
		floor = nil,
		now = 0,
		audioIndex = nil,
		loading = false,
		loadingId = 0,
		released = false,
		unjoined = false,
		dead = false,
		error = nil,
		onTrackEnd = nil,
		onError = nil,
		onStarted = nil
	}, AudioClient)
end

--- Starts the audio thread and makes the channels it reads and writes.
---@param pcmAddress string? # The shared spectrum ring's address; nil when the spectrum is local
---@return beat.AudioClient
function AudioClient.new(pcmAddress)
	reap()

	local commands = threading.channel()
	local events = threading.channel()
	local commandAddress, eventAddress = commands:address(), events:address()

	local ok, handle = pcall(threading.spawn, function()
		require("beat.app.services.playback.audio_thread").run(commandAddress, eventAddress, pcmAddress)
	end)
	if not ok then
		commands:close()
		events:close()
		error(handle, 2)
	end

	return AudioClient.attach(commands, events, handle --[[@as threading.Handle]])
end

--- Marks the command just sent as one whose track is not heard yet. Snapshots carry the id of the
--- last command they applied, so one with the id and a moving heard frame is what says the device
--- has started on it.
function AudioClient:beginLoading()
	self.loading = true
	self.loadingId = self.commandId
end

--- Whether the track the user asked for has yet to produce heard audio.
---@return boolean
function AudioClient:isLoading()
	return self.loading
end

---@param command beat.AudioMessage
---@param changesState boolean
---@return boolean sent
function AudioClient:send(command, changesState)
	self.commandId += 1
	command.id = self.commandId
	if changesState then self.stateId = self.commandId end
	return self.commands:push(command)
end

--- The next track's place, used by the load that starts it: a restored session asks for a seek
--- before anything is loaded, and the audio thread can open the source at that frame instead of
--- decoding from the top and throwing it away.
---@param seconds number
function AudioClient:setStartAt(seconds)
	self.pendingStartAt = math.max(0, seconds or 0)
end

--- What one queued track hands the audio thread: where it is and how to size its stream without
--- opening it first. A test or a caller with only paths gets the fields filled in later by the
--- reader, which is slower but still correct.
---@param path string
---@param sampleRate number?
---@param channels number?
---@param duration number?
---@return beat.AudioTrack
local function trackOf(path, sampleRate, channels, duration)
	local frameCount = nil
	if sampleRate ~= nil and sampleRate > 0 and duration ~= nil and duration > 0 then
		frameCount = math.floor(duration * sampleRate)
	end
	return { path = path, sampleRate = sampleRate, channels = channels, frameCount = frameCount }
end

--- Replaces what the audio thread is playing, starting paused or playing. The tracks after the
--- first are what treble stages behind it.
---@param tracks (string|beat.AudioTrack)[]
---@param startAt number?
---@param autoplay boolean?
---@param repeatOne boolean?
function AudioClient:load(tracks, startAt, autoplay, repeatOne)
	---@type beat.AudioTrack[]
	local queued = {}
	for at = 1, #tracks do
		local item = tracks[at]
		if type(item) == "string" then
			queued[at] = trackOf(item)
		else
			queued[at] = item
		end
	end

	self.pendingTracks = {}
	self.collecting = false
	self.endedId = nil
	self.at = startAt or 0
	self:send({
		kind = "load",
		tracks = queued,
		index = 1,
		startAt = startAt or 0,
		autoplay = autoplay ~= false,
		repeatOne = repeatOne == true
	}, true)
	if autoplay ~= false then
		self.playing = true
		self.sampledAt = self.now
		self:beginLoading()
	else
		self.loading = false
	end
end

--- Called by the queue when a track is appended while this player already has one: treble stages
--- it behind what it is decoding, so no reload is needed and nothing audible is cut.
---@param path string
---@param sampleRate number?
---@param channels number?
---@param duration number?
function AudioClient:enqueue(path, sampleRate, channels, duration)
	local track = trackOf(path, sampleRate, channels, duration)
	if self.collecting then
		self.pendingTracks[#self.pendingTracks + 1] = track
		return
	end
	self:send({ kind = "enqueue", track = track }, false)
end

--- Starts what was staged, or resumes a paused track.
function AudioClient:play()
	if self.collecting and #self.pendingTracks > 0 then
		local tracks = self.pendingTracks
		local startAt = self.pendingStartAt
		self.pendingStartAt = 0
		self:load(tracks, startAt, true, false)
		return
	end
	self.playing = true
	self.sampledAt = self.now
	self:send({ kind = "play" }, true)
	self:beginLoading()
end

function AudioClient:pause()
	self.loading = false
	if not self.playing then return end
	self.at = self:position()
	self.sampledAt = self.now
	self.playing = false
	self:send({ kind = "pause" }, true)
end

function AudioClient:stop()
	self.loading = false
	self.playing = false
	self.at = 0
	self.trackDuration = 0
	self.sampledAt = self.now
	self:send({ kind = "stop" }, true)
end

---@param seconds number
function AudioClient:seek(seconds)
	self.at = math.max(0, seconds or 0)
	self.sampledAt = self.now
	self:send({ kind = "seek", seconds = self.at }, true)
	-- Asking where a paused track would start is not a wait for audio: nothing was asked to play.
	if self.playing then self:beginLoading() end
end

--- Closes the audio thread's treble player and drops its queue, keeping the thread for the next
--- reload. This is what a track boundary and a skip do, so it must not cost a Lua state.
function AudioClient:close()
	self.loading = false
	self.collecting = true
	self.pendingTracks = {}
	-- A start place set for this load is kept: the player sets it just before a reload, and the
	-- load that follows is the one that consumes it.
	self.playing = false
	self.at = 0
	self.trackDuration = 0
	self.heard = 0
	self.written = nil
	self.floor = nil
	self:send({ kind = "close" }, true)
end

---@param value number
function AudioClient:setVolume(value)
	self:send({ kind = "volume", value = value }, false)
end

---@param bands treble.Equalizer.Band[]?
function AudioClient:setEqualizer(bands)
	self:send({ kind = "equalizer", bands = bands }, false)
end

---@param device string?
function AudioClient:setDevice(device)
	self:send({ kind = "device", device = device }, false)
end

---@param background boolean
function AudioClient:setBackground(background)
	self:send({ kind = "background", value = background }, false)
end

---@param snapshot beat.AudioMessage
function AudioClient:apply(snapshot)
	local commandId = snapshot.commandId
	-- The device played the last track out and has nothing after it: no snapshot queued at or
	-- before that end can say it is playing. One from a command the app sent since is newer and
	-- is the truth again.
	local afterEnd = self.endedId == nil or (commandId or 0) > self.endedId
	self.appliedId = commandId or self.appliedId
	self.trackDuration = snapshot.duration or 0
	self.audioIndex = snapshot.index or self.audioIndex
	local rate = snapshot.sampleRate
	if type(rate) == "number" then self.sampleRate = rate end

	-- A snapshot is the state after the commands it says it applied. Anything newer than that from
	-- this side -- a play, a seek -- is what the user is looking at, even though the device has not
	-- caught up yet; the next snapshot carries its command id and becomes the truth.
	if self.appliedId >= self.stateId then
		if afterEnd then self.playing = snapshot.playing == true end
		self.at = snapshot.position or 0
		self.heard = snapshot.heard or 0
		self.written = snapshot.written
		self.floor = snapshot.floor
		self.sampledAt = self.now
	end

	-- The command that asked for the track has been applied and the device has played some of it:
	-- the wait is over. The heard frame is treble's own count from the track's timeline, so a
	-- snapshot from before a load or seek has nought there and cannot end the wait early.
	if self.loading and self.appliedId >= self.loadingId and snapshot.playing == true and (snapshot.heard or 0) > 0 then
		self.loading = false
	end
end

--- One step on the app's thread: takes everything the audio thread reported, without touching a
--- file or the device. Called from the player's own `update`, before it looks at track transitions.
---@param now number?
function AudioClient:update(now)
	if now ~= nil then self.now = now end

	for _ = 1, 256 do
		local event = self.events:pop() --[[@as beat.AudioMessage?]]
		if event == nil then break end
		local kind = event.kind
		if kind == "snapshot" then
			self:apply(event)
		elseif kind == "ended" then
			self.loading = false
			-- The audio thread says nothing follows: the device has stopped, whatever a snapshot
			-- from before this moment still says. The pause button must not outlive the track.
			if event.last == true then
				self.endedId = self.appliedId
				self.playing = false
				self.sampledAt = self.now
			end
			if self.onTrackEnd ~= nil then self.onTrackEnd(event.completed == true) end
		elseif kind == "started" then
			local index = event.index
			if type(index) == "number" then
				self.endedId = nil
				self.audioIndex = index
				if self.onStarted ~= nil then self.onStarted(index) end
			end
		elseif kind == "error" then
			self.loading = false
			local message = event.message or "the audio thread reported an error"
			self.error = message
			if self.onError ~= nil then self.onError(message) end
		end
	end

	-- A thread that ended by itself will never answer again. Freezing the playhead and saying so
	-- is better than interpolating a position nothing is playing.
	local handle = self.handle
	if handle ~= nil and handle:done() then
		self.handle = nil
		local ok, err = pcall(handle.join, handle)
		self.closed = true
		self.commands:close()
		self.events:close()
		self.dead = true
		self.loading = false
		self.at = self:position()
		self.playing = false
		self.error = ok and "the audio thread stopped" or tostring(err)
		if self.onError ~= nil then self.onError(self.error) end
	end
end

--- Seconds into the current track, moved on since the last snapshot while it is playing.
---@return number
function AudioClient:position()
	local position = self.at
	if self.playing then position += math.max(0, self.now - self.sampledAt) end
	if self.trackDuration > 0 and position > self.trackDuration then position = self.trackDuration end
	return position
end

---@return number
function AudioClient:duration()
	return self.trackDuration
end

---@return boolean
function AudioClient:isPlaying()
	return self.playing
end

--- The device frame being heard, moved on like the position: what the spectrum's window ends at.
---@return number
function AudioClient:heardFrame()
	local heard = self.heard
	if self.playing and self.sampleRate ~= nil then
		heard += math.max(0, self.now - self.sampledAt) * self.sampleRate
		if self.written ~= nil and heard > self.written then heard = self.written end
	end
	return math.floor(heard)
end

--- treble's name for the frame being heard, which the player above asks for.
---@return number
function AudioClient:playedFrames()
	return self:heardFrame()
end

--- The ring's frame counts, for the spectrum to read what the audio thread wrote.
---@return number? written
---@return number? floor
function AudioClient:pcmState()
	return self.written, self.floor
end

--- Asks the audio thread to stop and gives the channels back. Joining waits only so long: a
--- decoder still blocked on a network mount must not hold the window open. Answers whether the
--- thread was joined; when it was not, the channels are kept alive for it and the caller must not
--- give back the PCM ring the thread may still be writing.
---@return boolean joined
function AudioClient:shutdown()
	if self.closed then return not (self.released or self.unjoined) end
	self.closed = true

	local commands, events = self.commands, self.events
	commands:push({ kind = "quit" })
	local handle = self.handle
	self.handle = nil
	if handle == nil then
		commands:close()
		events:close()
		return true
	end

	for _ = 1, 10 do
		if handle:done() then break end
		threading.sleep(5)
	end
	if handle:done() then
		pcall(handle.join, handle)
		commands:close()
		events:close()
		return true
	end

	abandoned.records[#abandoned.records + 1] = { handle = handle, commands = commands, events = events }
	self.unjoined = true
	return false
end

--- Asks every thread to stop without waiting and without giving anything back. What the app calls
--- as its window closes: the OS reclaims the threads and memory, and no Lua finalizer runs on an
--- object a thread may still be using.
function AudioClient:release()
	if self.closed then return end
	self.closed = true
	self.released = true
	self.unjoined = true
	local commands = self.commands
	if commands ~= nil then commands:push({ kind = "quit" }) end
end

return AudioClient
