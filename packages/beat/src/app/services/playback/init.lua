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
-- settle. While a track plays, its place is written this often, so a crash loses little of it.
local SESSION_DELAY = 1
local SESSION_STRIDE = 10

---@class beat.PlaybackService
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
local Playback = {}
Playback.__index = Playback
Playback.needs = { "settings", "library", "collections", "toasts", "emit"}
Playback.handles = {
	"togglePlay", "next", "previous", "seek", "volume", "mute", "shuffle", "repeat",
	"playAlbum", "playTrack", "playArtist", "playPlaylist", "playPlaylistTrack", "jumpTrack",
	"play", "pause", "stop", "queueAlbum",
}

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
		spectrum = Spectrum.new(),
		lastListenedTrackId = nil,
	}, Playback)

	-- The samples the audio device hands back are what the spectrum is made of; the player has no
	-- other reason to know the spectrum exists.
	self.player.onSamples = function(samples, frames, channels)
		self.spectrum:feed(samples, frames, channels)
	end

	local values = self.settings.values
	self.player:setVolume(values.volume)
	self.player.isMuted = values.isMuted

	self:restoreSession()
	self.sessionKey = self:sessionKeyOf()

	-- The player knows when a track actually starts or stops; everything listening to playback
	-- -- the tag store, Last.fm, a plugin -- hears it as a message rather than watching the queue.
	self.player.onTrackStarted = function(track, position)
		self.emit({ type = "trackStarted", track = track, position = position})
	end
	self.player.onTrackEnded = function(track, completed)
		self.emit({ type = "trackEnded", track = track, completed = completed})
	end
	self.player.onQueueChanged = function()
		self.emit({ type = "queueChanged"})
	end
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
	local queue, sameTrack = Queue.unpack(saved.queue, function(path) return byPath[path] end)
	if queue == nil then return end

	self.player:restore(queue, sameTrack and saved.seconds or 0)
	local current = queue:current()
	self.lastListenedTrackId = current and current.id or nil
end

--- What would be written, in a form that changes when the file would: the queue, where its play
--- head is, and -- to a stride -- how far into the track.
---@return string
function Playback:sessionKeyOf()
	local queue = self.player.queue
	if queue == nil then return "" end
	return table.concat({
		tostring(queue), tostring(queue.tracks), tostring(queue.order), #queue.order, queue.position,
		queue.repeatMode, tostring(queue.shuffle), queue.source,
		math.floor(self.player:position() / SESSION_STRIDE),
	}, "|")
end

--- Writes where listening is now. The window closing asks for it at once. A launch that never had
--- a queue -- its library still being scanned -- leaves the last session's file as it was.
function Playback:flush()
	local queue = self.player.queue
	if queue == nil and self.sessionKey == "" then return end
	Session.save({ queue = queue and queue:pack() or nil, seconds = self.player:position()})
	self.sessionKey = self:sessionKeyOf()
	self.sessionDueAt = nil
end

--- The track playing, for the bar and every page that marks the current row.
---@return beat.Track?
function Playback:current()
	return self.player:current()
end

--- A new library invalidates what is playing: its ids and paths are gone, so the queue, the
--- device and the spectrum go with it.
function Playback:reset()
	self.player:close()
	self.spectrum:clear()
end

-- Media controls
function Playback:play()
	if self.player.queue == nil then
		-- Set up the queue with the library's tracks
		local library = self.library.current
		if library ~= nil and #library.tracks > 0 then
			self.player:playTracks(library.tracks, 1, { source = "library"})
		end
		return
	end

	self.player:play()
end

function Playback:pause()
	self.player:pause()
end

function Playback:stop()
	self.player:stop()
end

--- The control with nothing queued starts something: the whole library. A page that has
--- something better to start -- an album page, its album -- answers `togglePlay` itself first.
function Playback:toggle()
	if self.player:isPlaying() then self:pause() else self:play() end
end

--- An album's play or shuffle. Playing the album already in the queue is the pause button, unless
--- the message asks for a restart: a menu's "Play album" means from the top, whatever is playing.
---@param albumId number
---@param shuffle boolean
---@param restart boolean
function Playback:playAlbum(albumId, shuffle, restart)
	local library = self.library.current
	local album = library ~= nil and library:album(albumId) or nil
	if album == nil then return end

	local current = self.player:current()
	if not shuffle and not restart and current ~= nil and current.albumId == album.id then
		self.player:toggle()
	elseif shuffle then
		self.player:playTracks(album.tracks, 1, { shuffle = true, source = "album"})
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
	local album = library ~= nil and library:album(albumId) or nil
	if album == nil then return end

	if asNext then
		self.player:playNext(album.tracks)
		self.toasts:show("Playing next · " .. album.title)
	else
		self.player:addToQueue(album.tracks)
		self.toasts:show("Added to queue · " .. album.title)
	end
end

--- A track row. Which album or artist it was clicked on decides what the queue holds after it.
--- The current track's row is its pause button, unless the message asks for a restart.
---@param message table
function Playback:playTrack(message)
	local library = self.library.current
	local track = library ~= nil and library:track(message.trackId) or nil
	local tracks = nil
	if message.albumId ~= nil and library ~= nil then
		local album = library:album(message.albumId --[[@as number]])
		tracks = album and album.tracks
	elseif message.artistId ~= nil and library ~= nil then
		local artist = library:artist(message.artistId --[[@as number]])
		tracks = artist and artist.tracks
	end

	local current = self.player:current()
	if track ~= nil and not message.restart and current ~= nil and current.id == track.id then
		self.player:toggle()
	elseif track ~= nil then
		self.player:playTrack(track, tracks)
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
	self.player:playTracks(tracks, 1, {
		source = "playlist:" .. tostring(playlist.id),
		shuffle = shuffle,
	})
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
		if track.id == trackId then index = at; break end
	end
	if #tracks > 0 then
		self.player:playTracks(tracks, index, { source = "playlist:" .. tostring(playlist.id)})
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

function Playback:update(message)
	local kind = message.type
	if kind == "togglePlay" then
		self:toggle()
	elseif kind == "next" then
		self.player:next()
	elseif kind == "previous" then
		self.player:previous()
	elseif kind == "seek" then
		local seconds = message.seconds
		if message.by ~= nil then seconds = self.player:position() + message.by end
		self.player:seek(math.max(0, seconds or 0))
	elseif kind == "volume" then
		self:setVolume(message.value)
	elseif kind == "mute" then
		self:toggleMute()
	elseif kind == "shuffle" then
		local queue = self.player.queue
		if queue ~= nil then self.player:setShuffle(not queue.shuffle) end
	elseif kind == "repeat" then
		self.player:cycleRepeat()
	elseif kind == "playAlbum" then
		self:playAlbum(message.id --[[@as number]], message.shuffle == true, message.restart == true)
	elseif kind == "queueAlbum" then
		self:queueAlbum(message.id --[[@as number]], message.next == true)
	elseif kind == "playTrack" then
		self:playTrack(message)
	elseif kind == "playArtist" then
		local library = self.library.current
		local artist = library ~= nil and library:artist(message.id --[[@as number]]) or nil
		if artist ~= nil then self.player:playArtist(artist, message.trackId) end
	elseif kind == "playPlaylist" then
		self:playPlaylist(message.id --[[@as number]], message.shuffle == true)
	elseif kind == "playPlaylistTrack" then
		self:playPlaylistTrack(message.playlistId --[[@as number]], message.trackId --[[@as number]])
	elseif kind == "jumpTrack" then
		self.player:jump(message.trackId)
	elseif kind == "play" then
		self:play()
	elseif kind == "pause" then
		self:pause()
	elseif kind == "stop" then
		self:stop()
	end
end

--- A listen is counted once per track, when playback has actually started it: that is what the
--- playlist it came from, its album and its tags remember. Whether the same track is scrobbled is
--- the Last.fm service's question; it reads the player for itself.
function Playback:step(now)
	local changed = false

	if self.player:update(now) then changed = true end
	local current = self.player:current()
	local playing = self.player:isPlaying()
	if playing and current ~= nil and self.library.current ~= nil
	and current.id ~= self.lastListenedTrackId then
		self.lastListenedTrackId = current.id
		local playlistId = nil
		local source = self.player.queue and self.player.queue.source
		if source ~= nil then
			local id = source:match("^playlist:(%d+)$")
			if id ~= nil then playlistId = tonumber(id) end
		end
		self.collections:recordListen(current, playlistId, os.time())
		changed = true
	end

	if self.spectrum:step(now) then changed = true end

	local err = self.player:takeError()
	if err ~= nil then
		---@cast err string
		self.toasts:show(err, "error")
		changed = true
	end

	if self.sessionDueAt == nil and self:sessionKeyOf() ~= self.sessionKey then
		self.sessionDueAt = now + SESSION_DELAY
	end
	if self.sessionDueAt ~= nil and now >= self.sessionDueAt then self:flush() end

	return changed, playing
end

--- The old player goes when the app is set up again, so a test that makes many apps does not keep
--- one alive per app.
function Playback:close()
	-- The app is being torn down, not a track being ended for anybody still listening.
	self.player.onTrackStarted = nil
	self.player.onTrackEnded = nil
	self.player.onQueueChanged = nil
	self.player:close()
	self.spectrum:clear()
end

return Playback
