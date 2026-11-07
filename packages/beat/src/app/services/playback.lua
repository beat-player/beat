-- Everything that makes a sound: the audio player, the spectrum the bar draws, Last.fm and the
-- scrobbler. They are one service because they are one act -- a track starts, the queue advances,
-- a listen counts, a scrobble leaves -- and because none of them means anything without the others.
-- Views read `player`, `spectrum` and `lastfm` to draw the bar; nothing outside changes them, so
-- every control that moves playback arrives here as a message.
local core = require("beat-core")
local LastfmClient = require("beat.app.lastfm")

local util = core.util

---@class beat.PlaybackService
---@field player beat.Player
---@field spectrum beat.Spectrum
---@field scrobbler beat.Scrobbler
---@field lastfm beat.LastfmClient
---@field lastListenedTrackId number? # The track a listen has already been counted for
---@field settings beat.SettingsService
---@field library beat.LibraryService
---@field collections beat.CollectionsService
---@field toasts beat.ToastsService
local Playback = {}
Playback.__index = Playback
Playback.needs = { "settings", "library", "collections", "toasts"}
Playback.handles = {
	"togglePlay", "next", "previous", "seek", "volume", "mute", "shuffle", "repeat",
	"playAlbum", "playTrack", "playArtist", "playPlaylist", "playPlaylistTrack", "jumpTrack",
	"lastfmConnect", "lastfmCancel", "lastfmOpenAuth", "lastfmDisconnect", "lastfmEnabled",
}

---@param deps {
--- settings: beat.SettingsService,
--- library: beat.LibraryService,
--- collections: beat.CollectionsService,
--- toasts: beat.ToastsService,
--- }
---@return beat.PlaybackService
function Playback.new(deps)
	local self = setmetatable({
		settings = deps.settings,
		library = deps.library,
		collections = deps.collections,
		toasts = deps.toasts,
		player = core.Player.new(),
		scrobbler = core.Scrobbler.new(),
		spectrum = core.Spectrum.new(),
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
	self.player:setEqualizer(core.equalizer.bands(values.equalizerGains))
	-- Last.fm keeps its own authorisation state, so the handlers are the only way it says anything
	-- to the rest of the app: a toast, and a request to write what it just changed in settings.
	self.lastfm = LastfmClient.new(values, {
		onToast = function(text, tone) self.toasts:show(text, tone) end,
		onSave = function() self.settings:save() end,
	})

	return self
end

--- The track playing, for the bar and every page that marks the current row.
---@return beat.Track?
function Playback:current()
	return self.player:current()
end

--- A new library invalidates what is playing: its ids and paths are gone, so the queue, the
--- device and the spectrum go with it.
function Playback:stop()
	self.player:close()
	self.spectrum:clear()
end

--- The control with nothing queued starts something: the whole library. A page that has
--- something better to start -- an album page, its album -- answers `togglePlay` itself first.
function Playback:toggle()
	if self.player.queue == nil then
		local library = self.library.current
		if library ~= nil and #library.tracks > 0 then
			self.player:playTracks(library.tracks, 1, { source = "library"})
		end
	else
		self.player:toggle()
	end
end

--- An album's play or shuffle. Playing the album already in the queue is the pause button.
---@param albumId number
---@param shuffle boolean
function Playback:playAlbum(albumId, shuffle)
	local library = self.library.current
	local album = library ~= nil and library:album(albumId) or nil
	if album == nil then return end

	local current = self.player:current()
	if not shuffle and current ~= nil and current.albumId == album.id then
		self.player:toggle()
	elseif shuffle then
		self.player:playTracks(album.tracks, 1, { shuffle = true, source = "album"})
	else
		self.player:playAlbum(album)
	end
end

--- A track row. Which album or artist it was clicked on decides what the queue holds after it.
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
	if track ~= nil and current ~= nil and current.id == track.id then
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
	values.volume = util.clamp(value or 0, 0, 1)
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
		self:playAlbum(message.id --[[@as number]], message.shuffle == true)
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
	elseif kind == "lastfmConnect" then
		self.lastfm:connect()
	elseif kind == "lastfmCancel" then
		self.lastfm:cancelAuth()
	elseif kind == "lastfmOpenAuth" then
		if not self.lastfm:openAuthPage() then
			self.toasts:show("Could not open a browser for Last.fm", "error")
		end
	elseif kind == "lastfmDisconnect" then
		self.lastfm:disconnect()
	elseif kind == "lastfmEnabled" then
		self.settings.values.lastfmEnabled = message.value == true
		self.settings:changed()
	end
end

--- A listen is counted once per track, when playback has actually started it: that is what the
--- playlist it came from, its album and its tags remember. Scrobbling is the same track seen by
--- Last.fm, so it is fed every tick rather than once.
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

	self.scrobbler:update(current, self.player:position(), playing, os.time())
	if self.lastfm:update(current, playing, self.scrobbler:take()) then changed = true end
	if self.spectrum:step(now) then changed = true end

	local err = self.player:takeError()
	if err ~= nil then
		---@cast err string
		self.toasts:show(err, "error")
		changed = true
	end

	return changed, playing or self.lastfm:isBusy()
end

--- The old player and libcurl handle go when the app is set up again, so a test that makes many
--- apps does not keep one of each alive per app.
function Playback:close()
	self.lastfm:close()
	self.player:close()
	self.spectrum:clear()
end

return Playback
