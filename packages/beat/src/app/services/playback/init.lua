-- Everything that makes a sound: the audio player, the queue and the spectrum the bar draws. They
-- are one service because they are one act -- a track starts, the queue advances, a listen counts
-- -- and because none of them means anything without the others. Views read `player` and
-- `spectrum` to draw the bar; nothing outside changes them, so every control that moves playback
-- arrives here as a message. Last.fm is deliberately not here: it watches what this plays from
-- its own service, and nothing about playing depends on it.
local Player = require("beat.app.services.playback.player")
local Queue = require("beat.app.services.playback.queue")
local Session = require("beat.app.services.playback.session")
local Spectrum = require("beat.app.services.playback.spectrum")

-- A change to the queue comes in bursts -- a shuffle, then a skip -- so it is written once they
-- settle. While a track plays, its place is written this often, so a crash loses little of it: once
-- every thirty seconds on a window somebody is looking at, and every minute once it is hidden and
-- nothing is drawn. Both are only the place inside the track: the queue itself is encoded once and
-- reused until one of its own fields changes.
local SESSION_DELAY = 1
local SESSION_STRIDE = 30
local BACKGROUND_SESSION_STRIDE = 60

--- Whether the part of the session the queue owns -- everything `Queue:pack` writes -- differs
--- from what was last written. The queue mutates in place, so the arrays it replaces and the
--- numbers it moves are compared rather than a string built from them.
---@param self beat.PlaybackService
---@param queue beat.Queue
local function queueChangedForSession(self, queue)
	return queue ~= self.sessionQueue
		or queue.tracks ~= self.sessionTracks
		or queue.order ~= self.sessionOrder
		or queue.naturalOrder ~= self.sessionNaturalOrder
		or #queue.order ~= self.sessionOrderCount
		or queue.position ~= self.sessionPosition
		or queue.repeatMode ~= self.sessionRepeatMode
		or queue.shuffle ~= self.sessionShuffle
		or queue.source ~= self.sessionSource
end

--- Takes the queue and play head as they stand for the next comparison, after a write or at
--- start-up. The encoded queue string is kept: a later write that only moves the play head reuses
--- it rather than encoding the paths, order and settings again.
---@param self beat.PlaybackService
local function rememberSession(self)
	local queue = self.player.queue
	if queue ~= nil then
		self.sessionQueue = queue
		self.sessionTracks = queue.tracks
		self.sessionOrder = queue.order
		self.sessionNaturalOrder = queue.naturalOrder
		self.sessionOrderCount = #queue.order
		self.sessionPosition = queue.position
		self.sessionRepeatMode = queue.repeatMode
		self.sessionShuffle = queue.shuffle
		self.sessionSource = queue.source
	else
		self.sessionQueue = nil
		self.sessionTracks = nil
		self.sessionOrder = nil
		self.sessionNaturalOrder = nil
		self.sessionOrderCount = 0
		self.sessionPosition = 0
		self.sessionRepeatMode = nil
		self.sessionShuffle = nil
		self.sessionSource = nil
		self.sessionQueueJson = nil
	end
	local stride = self.player.background and BACKGROUND_SESSION_STRIDE or SESSION_STRIDE
	self.sessionBucket = math.floor(self.player:position() / stride)
	self.sessionKey = self:sessionKeyOf()
end

---@class beat.PlaybackService: beat.Service
---@field player beat.Player
---@field spectrum beat.Spectrum
---@field lastListenedTrackId number? # The track a listen has already been counted for
---@field settings beat.SettingsService
---@field library beat.LibraryService
---@field collections beat.CollectionsService
---@field toasts beat.ToastsService
---@field emit fun(message: table) # Sends an event to whoever is listening; delivered after this message
---@field sessionKey string # What the session file holds, as `sessionKeyOf` puts it
---@field sessionDueAt number? # When a changed session is to be written
---@field sessionQueue beat.Queue? # The queue as last written, and the fields below, so a tick compares numbers instead of building a key
---@field sessionTracks beat.Track[]?
---@field sessionOrder number[]?
---@field sessionNaturalOrder number[]?
---@field sessionOrderCount number
---@field sessionPosition number
---@field sessionRepeatMode string?
---@field sessionShuffle boolean?
---@field sessionSource string?
---@field sessionBucket number? # The SESSION_STRIDE-sized step of the play head last written
---@field sessionQueueJson string? # The queue's encoded part, reused until the queue itself changes
---@field shownSecond number? # The second of the track the bar's clock was last laid out for
---@field shownTrackId number? # And the track and whether it played, which the bar is laid out from
---@field shownPlaying boolean?
---@field shownLoading boolean? # Whether the loading indicator was up in the frame last drawn
local Playback = {}
Playback.__index = Playback
Playback.needs = { "settings", "library", "collections", "toasts", "emit" }

---@param deps {
--- settings: beat.SettingsService,
--- library: beat.LibraryService,
--- collections: beat.CollectionsService,
--- toasts: beat.ToastsService,
--- emit: fun(message: table),
--- }
---@return beat.PlaybackService
function Playback.new(deps)
	local self = setmetatable({
		settings = deps.settings,
		library = deps.library,
		collections = deps.collections,
		toasts = deps.toasts,
		emit = deps.emit,
		player = Player.new(),
		-- The audio thread writes the PCM the meter is made of into the ring the player made.
		spectrum = nil,
		shownLoading = nil,
		lastListenedTrackId = nil,
		sessionKey = "",
		sessionDueAt = nil,
		sessionQueue = nil,
		sessionTracks = nil,
		sessionOrder = nil,
		sessionNaturalOrder = nil,
		sessionOrderCount = 0,
		sessionPosition = 0,
		sessionRepeatMode = nil,
		sessionShuffle = nil,
		sessionSource = nil,
		sessionBucket = nil,
		sessionQueueJson = nil
	}, Playback)

	local pcm = self.player.pcm --[[@as beat.PcmRing]]
	self.spectrum = Spectrum.new(pcm.pointer)

	local values = self.settings.values
	self.player:setVolume(values.volume)
	self.player.isMuted = values.isMuted

	self:restoreSession()
	rememberSession(self)

	-- The player knows when a track actually starts or stops; everything listening to playback
	-- -- the tag store, Last.fm, a plugin -- hears it as a message rather than watching the queue.
	self.player.onTrackStarted = |track, position| -> self.emit({
		type = "trackStarted",
		track = track,
		position = position
	})
	self.player.onTrackEnded = |track, completed| -> self.emit({
		type = "trackEnded",
		track = track,
		completed = completed
	})
	self.player.onQueueChanged = || -> self.emit({ type = "queueChanged" })
	return self
end

--- Carries on from where the last launch stopped: the queue it had, paused where its track was.
--- The track is not a new listen; it was counted when it first started.
function Playback:restoreSession()
	local library = self.library.current
	local saved = Session.load()
	if library == nil or saved == nil or saved.queue == nil then return end

	local byPath = {}
	for _, track in ipairs(library.tracks) do byPath[track.path] = track end
	local queue, sameTrack = Queue.unpack(saved.queue, |path| -> byPath[path])
	if queue == nil then return end

	self.player:restore(queue, sameTrack and saved.seconds or 0)
	local current = queue:current()
	self.lastListenedTrackId = current?.id
end

--- What would be written, in a form that changes when the file would: the queue, where its play
--- head is, and -- to the stride the window's state asks for -- how far into the track.
---@return string
function Playback:sessionKeyOf()
	local queue = self.player.queue
	if queue == nil then return "" end
	local stride = self.player.background and BACKGROUND_SESSION_STRIDE or SESSION_STRIDE
	return table.concat({
		tostring(queue),
		tostring(queue.tracks),
		tostring(queue.order),
		#queue.order,
		queue.position,
		queue.repeatMode,
		tostring(queue.shuffle),
		queue.source,
		math.floor(self.player:position() / stride)
	}, "|")
end

--- Whether a tick would write something the file does not already hold. Compared field by field:
--- this runs every tick, so it does not build the key or pack the queue to find out. The queue
--- itself is everything `Queue:pack` keeps; the play head in it moves on a skip, while how far
--- into the track it is moves every frame and is compared only once per stride.
---@return boolean
function Playback:sessionChanged()
	local queue = self.player.queue
	if queue == nil then return self.sessionKey ~= "" end
	if queueChangedForSession(self, queue) then return true end
	local stride = self.player.background and BACKGROUND_SESSION_STRIDE or SESSION_STRIDE
	return math.floor(self.player:position() / stride) ~= self.sessionBucket
end

--- Writes where listening is now. The window closing asks for it at once. A launch that never had
--- a queue -- its library still being scanned -- leaves the last session's file as it was.
function Playback:flush()
	local queue = self.player.queue
	if queue == nil and self.sessionKey == "" then return end

	-- The queue is most of the file and changes rarely. A write that only moves the play head
	-- hands `Session.save` the queue's encoded part from the last one instead of encoding it again;
	-- while the same queue is playing, this is what keeps a position save from touching its paths.
	local packed = nil
	local queueJson = nil
	if queue ~= nil then
		if self.sessionQueueJson == nil or queueChangedForSession(self, queue) then
			local packedQueue = queue:pack()
			packed = packedQueue
			queueJson = Session.encodeQueue(packedQueue)
			self.sessionQueueJson = queueJson
		else
			queueJson = self.sessionQueueJson
		end
	end
	Session.save({ queue = packed, seconds = self.player:position() }, nil, queueJson)
	rememberSession(self)
	self.sessionDueAt = nil
end

--- The track playing, for the bar and every page that marks the current row.
---@return beat.Track?
function Playback:current()
	return self.player:current()
end

--- Whether the player is still waiting for the track the user asked for to be heard.
---@return boolean
function Playback:isLoading()
	return self.player:isLoading()
end

--- A new library invalidates what is playing: its ids and paths are gone, so the queue, the
--- device and the spectrum go with it.
function Playback:reset()
	self.player:close()
	-- `close` replaces the ring when the old audio thread could not be joined, so the spectrum is
	-- made again around whatever ring the player will use next rather than left on the old one.
	local pcm = assert(self.player.pcm)
	self.spectrum = Spectrum.new(pcm.pointer)
end

-- Media controls
function Playback:play()
	if self.player.queue == nil then
		-- Set up the queue with the library's tracks
		local library = self.library.current
		if library ~= nil and #library.tracks > 0 then
			self.player:playTracks(library.tracks, 1, { source = "library" })
		end
		return
	end

	self.player:play()
end

function Playback:pause()
	self.player:pause()
	-- A pause is a place worth remembering at once: the next launch carries on there even if the
	-- process ends before the stride's next write.
	self:flush()
end

function Playback:stop()
	self.player:stop()
end

--- The control with nothing queued starts something: the whole library. A page that has
--- something better to start -- an album page, its album -- answers `togglePlay` itself first.
function Playback:toggle()
	if self.player:isPlaying() then
		self:pause()
	else
		self:play()
	end
end

--- An album's play or shuffle. Playing the album already in the queue is the pause button, unless
--- the message asks for a restart: a menu's "Play album" means from the top, whatever is playing.
---@param albumId number
---@param shuffle boolean
---@param restart boolean
function Playback:playAlbum(albumId, shuffle, restart)
	local library = self.library.current
	local album = library ~= nil ? (library:album(albumId)) : nil
	if album == nil then return end

	local current = self.player:current()
	if not shuffle and not restart and current ~= nil and current.albumId == album.id then
		self.player:toggle()
	elseif shuffle then
		self.player:playTracks(album.tracks, nil, { shuffle = true, source = "album" })
	else
		self.player:playAlbum(album)
	end
end

--- An album put after the current track, or after everything queued, without interrupting what
--- plays now. This is the album menu's "Play next" and "Add to queue", which used to reach into
--- the player from the overlay.
---@param albumId number
---@param asNext boolean? # True puts it after the current track; false at the end of the queue
function Playback:queueAlbum(albumId, asNext)
	local library = self.library.current
	local album = library ~= nil ? (library:album(albumId)) : nil
	if album == nil then return end

	if asNext then
		self.player:playNext(album.tracks)
		self.toasts:show("Playing next · " .. album.title)
	else
		self.player:addToQueue(album.tracks)
		self.toasts:show("Added to queue · " .. album.title)
	end
end

--- A track row. What the row was listed in decides what the queue holds after it: an album's
--- rows queue the album, an artist's the artist, and a list that only knows its own ids -- the
--- search results -- queues them in the order it showed them. The current track's row is its
--- pause button, unless the message asks for a restart.
---@param message beat.PlayTrackMessage
function Playback:playTrack(message)
	local library = self.library.current
	local track = library ~= nil ? (library:track(message.trackId)) : nil
	local tracks = nil
	local source = "track"
	if message.trackIds ~= nil and #message.trackIds > 0 and library ~= nil then
		tracks = {}
		for _, id in ipairs(message.trackIds) do
			local listed = library:track(id)
			if listed ~= nil then tracks[#tracks + 1] = listed end
		end
		source = "search"
	elseif message.albumId ~= nil and library ~= nil then
		local album = library:album(message.albumId --[[@as number]] )
		tracks = album?.tracks
		source = "album"
	elseif message.artistId ~= nil and library ~= nil then
		local artist = library:artist(message.artistId --[[@as number]] )
		tracks = artist?.tracks
		source = "artist"
	end

	local current = self.player:current()
	if track ~= nil and not message.restart and current ~= nil and current.id == track.id then
		self.player:toggle()
	elseif track ~= nil then
		self.player:playTrack(track, tracks, nil, source)
	end
end

--- Starts a playlist from its page, shuffled or in order. It has to hold tracks the library
--- showing still has, or there is nothing to play.
---@param playlistId number
---@param shuffle boolean
---@return boolean
function Playback:playPlaylist(playlistId, shuffle)
	local playlist = self.collections.taxonomy:playlist(playlistId)
	if playlist == nil or self.library.current == nil then return false end
	local tracks = self.collections:playlistTracks(playlist)
	if #tracks == 0 then
		self.toasts:show("That playlist has no tracks yet", "error")
		return false
	end
	self.player:playTracks(tracks, nil, { source = "playlist:" .. tostring(playlist.id), shuffle = shuffle })
	self.toasts:show("Playing " .. playlist.name)
	return true
end

--- A track inside a playlist: the queue is the playlist from that row on, so the tracks after it
--- are its own rather than the library's.
---@param playlistId number
---@param trackId number
function Playback:playPlaylistTrack(playlistId, trackId)
	local playlist = self.collections.taxonomy:playlist(playlistId)
	if playlist == nil then return end
	local tracks = self.collections:playlistTracks(playlist)
	local index = 1
	for at, track in ipairs(tracks) do
		if track.id == trackId then
			index = at
			break
		end
	end
	if #tracks > 0 then
		self.player:playTracks(tracks, index, { source = "playlist:" .. tostring(playlist.id) })
	end
end

--- The volume slider. Moving it is also how a muted player comes back, so it unmutes.
---@param value number?
function Playback:setVolume(value)
	local values = self.settings.values
	values.volume = math.max(0, math.min(1, value or 0))
	values.isMuted = false
	self.player.isMuted = false
	self.player:setVolume(values.volume)
	self.settings:changed()
end

function Playback:toggleMute()
	self.settings.values.isMuted = self.player:toggleMute()
	self.settings:changed()
end

--- `repeat` is a keyword, so its handler cannot be a named field; it lives outside the table to
--- keep the same annotations as the rest.
---@param self beat.PlaybackService
---@param message beat.RepeatMessage
local function cycleRepeat(self, message)
	self.player:cycleRepeat()
end

Playback.on = {
	--- The bar's button, and a page's "play" that has nothing better to start.
	---@param self beat.PlaybackService
	---@param message beat.TogglePlayMessage
	togglePlay = function(self, message) self:toggle() end,
	---@param self beat.PlaybackService
	---@param message beat.NextMessage
	next = function(self, message) self.player:next() end,
	---@param self beat.PlaybackService
	---@param message beat.PreviousMessage
	previous = function(self, message) self.player:previous() end,
	--- The progress bar asks for an absolute place; the keys step by `by`.
	---@param self beat.PlaybackService
	---@param message beat.SeekMessage
	seek = function(self, message)
		local seconds = message.seconds
		if message.by ~= nil then seconds = self.player:position() + message.by end
		self.player:seek(math.max(0, seconds or 0))
	end,
	---@param self beat.PlaybackService
	---@param message beat.VolumeMessage
	volume = function(self, message) self:setVolume(message.value) end,
	---@param self beat.PlaybackService
	---@param message beat.MuteMessage
	mute = function(self, message) self:toggleMute() end,
	---@param self beat.PlaybackService
	---@param message beat.ShuffleMessage
	shuffle = function(self, message)
		local queue = self.player.queue
		if queue ~= nil then self.player:setShuffle(not queue.shuffle) end
	end,
	["repeat"] = cycleRepeat,
	---@param self beat.PlaybackService
	---@param message beat.PlayAlbumMessage
	playAlbum = function(self, message)
		self:playAlbum(message.id, message.shuffle == true, message.restart == true)
	end,
	---@param self beat.PlaybackService
	---@param message beat.QueueAlbumMessage
	queueAlbum = function(self, message) self:queueAlbum(message.id, message.next == true) end,
	---@param self beat.PlaybackService
	---@param message beat.PlayTrackMessage
	playTrack = function(self, message) self:playTrack(message) end,
	---@param self beat.PlaybackService
	---@param message beat.PlayArtistMessage
	playArtist = function(self, message)
		local library = self.library.current
		local artist = library ~= nil ? (library:artist(message.id)) : nil
		if artist ~= nil then self.player:playArtist(artist, message.trackId) end
	end,
	---@param self beat.PlaybackService
	---@param message beat.PlayPlaylistMessage
	playPlaylist = function(self, message) self:playPlaylist(message.id, message.shuffle == true) end,
	---@param self beat.PlaybackService
	---@param message beat.PlayPlaylistTrackMessage
	playPlaylistTrack = function(self, message)
		self:playPlaylistTrack(message.playlistId, message.trackId)
	end,
	---@param self beat.PlaybackService
	---@param message beat.JumpTrackMessage
	jumpTrack = function(self, message) self.player:jump(message.trackId) end,
	---@param self beat.PlaybackService
	---@param message beat.PlayMessage
	play = function(self, message) self:play() end,
	---@param self beat.PlaybackService
	---@param message beat.PauseMessage
	pause = function(self, message) self:pause() end,
	---@param self beat.PlaybackService
	---@param message beat.StopMessage
	stop = function(self, message) self:stop() end
}

--- A tick of the player and of the meter. Returns whether the view has to be built again, how soon
--- it wants the next tick -- `true` for the display's rate, a number of seconds for anything slower,
--- false when nothing moves -- and whether what only the canvases draw moved -- the playhead and the
--- spectrum -- which a repaint of the screen already built shows.
---
--- What playing moves is a canvas: the bar's fill and nub, and the meter behind it. The audio
--- thread reports thirty times a second and the playhead asks for a frame only when it moves a
--- pixel, so thirty frames a second is enough for both; sixty would draw the same ones again.
--- What it moves once a second is text -- the elapsed clock -- and a track that changes or starts
--- or stops is the whole bar laid out again, so those are the rebuilds.
---@param now number
---@return boolean changed
---@return boolean|number busy
---@return boolean repaint
function Playback:step(now)
	local changed = false
	local repaint = false

	local moved, structural = self.player:update(now)
	if structural then changed = true end

	-- The spinner is a canvas: while a track is still being opened or buffered, every frame draws
	-- it a little further round, so the app must keep asking for frames even when nothing else
	-- moves. A place that moved while nothing is heard is no reason to draw the playhead.
	local loading = self.player:isLoading()
	if moved and not loading then repaint = true end
	if loading then repaint = true end
	local wasLoading = self.shownLoading == true
	if self.shownLoading == nil then
		self.shownLoading = loading
	elseif self.shownLoading ~= loading then
		self.shownLoading = loading
		changed = true
	end
	-- A track being opened has no meter: the bars fall to rest rather than reading the ring the
	-- previous track left while nothing of the new one has been heard.
	if loading and not wasLoading then self.spectrum:clear() end

	local current = self.player:current()
	local playing = self.player:isPlaying()
	-- A listen is counted once per track, when playback has actually started it: that is what the
	-- playlist it came from, its album and its tags remember. Whether the same track is scrobbled
	-- is the Last.fm service's question; it reads the player for itself.
	if self.player:isAudible() and current ~= nil and self.library.current ~= nil and current.id ~= self.lastListenedTrackId then
		self.lastListenedTrackId = current.id
		local playlistId = nil
		local source = self.player.queue?.source
		if source ~= nil then
			local id = source:match("^playlist:(%d+)$")
			if id ~= nil then playlistId = tonumber(id) end
		end
		self.collections:recordListen(current, playlistId, os.time())
		changed = true
	end

	-- What the bar is laid out from: the clocks beside it, which are text, the track, and whether
	-- it plays. The elapsed clock only reads differently once the second it shows is another --
	-- `format.clock` rounds to the nearest second, so this is the same rounding, advanced from the
	-- same position the view reads. A track and a play button are what the rest of the bar is.
	local second = math.floor(self.player:position() + 0.5)
	local trackId = current?.id
	if self.shownSecond == nil then
		-- The first step records what the frame just drawn is from rather than asking for the same
		-- frame again: nothing has changed since it was drawn.
		self.shownSecond, self.shownTrackId, self.shownPlaying = second, trackId, playing
	elseif second ~= self.shownSecond or trackId ~= self.shownTrackId or playing ~= self.shownPlaying then
		self.shownSecond, self.shownTrackId, self.shownPlaying = second, trackId, playing
		changed = true
	end

	-- This brings the spectrum's frame count up to what the last snapshot reported. Before a
	-- player exists there is nothing to ask, and the meter holds at rest. A track still loading or
	-- buffering has nothing heard to analyse, and the ring still holds the previous track's audio:
	-- the bars stay at rest until frames of the new one are on the device.
	local meterEasing = false
	if not loading then
		local written, floor = self.player:pcmState()
		if written ~= nil then self.spectrum:sync(written, floor) end

		local meterChanged
		meterChanged, meterEasing = self.spectrum:step(now, self.player:heardFrame())
		if meterChanged then repaint = true end
	end

	local err = self.player:takeError()
	if err ~= nil then
		---@cast err string
		self.toasts:show(err, "error")
		changed = true
	end

	if self.sessionDueAt == nil and self:sessionChanged() then
		self.sessionDueAt = now + SESSION_DELAY
	end
	if self.sessionDueAt ~= nil and now >= self.sessionDueAt then self:flush() end

	-- The meter falling back to rest after the music stops is worth the slower tick a moving meter
	-- asks for; a track still being opened is the spinner, which is drawn at the display's rate.
	local busy = false
	if loading then
		busy = true
	elseif playing or meterEasing then
		busy = 1 / 30
	end
	return changed, busy, repaint
end

--- The old player goes when the app is set up again, so a test that makes many apps does not keep
--- one alive per app.
function Playback:close()
	-- The app is being torn down, not a track being ended for anybody still listening.
	self.player.onTrackStarted = nil
	self.player.onTrackEnded = nil
	self.player.onQueueChanged = nil
	self.player:destroy()
	self.spectrum:clear()
end

--- The window is closing: tell the audio thread to stop without waiting for it or giving back
--- what it may still use. The process ending is what reclaims the thread and its memory.
function Playback:release()
	self.player:release()
end

return Playback
