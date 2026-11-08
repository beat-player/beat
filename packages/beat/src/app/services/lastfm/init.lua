-- Last.fm, on its own: the desktop client and the scrobbler that decides when a track has been
-- heard. Playback plays and knows nothing about it; this service reads what playback is doing
-- every tick, so a scrobble is the track actually playing rather than what a control asked for.
-- Its connection state is in settings and its only way of speaking is a toast (and a request that
-- settings be saved), so a library change or a new queue cannot leave it holding stale state.
local Scrobbler = require("beat.app.services.lastfm.scrobbler")
local LastfmClient = require("beat.app.services.lastfm.client")

---@class beat.LastfmService: beat.Service
---@field client beat.LastfmClient
---@field scrobbler beat.Scrobbler
---@field settings beat.SettingsService
---@field toasts beat.ToastsService
---@field playback beat.PlaybackService
---@field system beat.SystemService
local Lastfm = {}
Lastfm.__index = Lastfm
Lastfm.needs = { "settings", "toasts", "playback", "system" }
Lastfm.handles = {
	"lastfmConnect", "lastfmCancel", "lastfmOpenAuth", "lastfmDisconnect", "lastfmEnabled",
}

---@param deps {
--- settings: beat.SettingsService,
--- toasts: beat.ToastsService,
--- playback: beat.PlaybackService,
--- system: beat.SystemService,
--- }
---@return beat.LastfmService
function Lastfm.new(deps)
	local self = setmetatable({
		settings = deps.settings,
		toasts = deps.toasts,
		playback = deps.playback,
		system = deps.system,
		scrobbler = Scrobbler.new(),
	}, Lastfm)

	-- Last.fm keeps its own authorisation state, so the handlers are the only way it says anything
	-- to the rest of the app: a toast, and a request to write what it just changed in settings.
	-- Opening the authorization page is a link like any other, so it goes through the service that
	-- owns that rather than a second copy of the platform's browser command.
	self.client = LastfmClient.new(self.settings.values, {
		onToast = function(text, tone) self.toasts:show(text, tone) end,
		onSave = function() self.settings:save() end,
	}, {
		openBrowser = function(url) return self.system:open(url) end,
	})

	return self
end

function Lastfm:update(message)
	local kind = message.type
	if kind == "lastfmConnect" then
		self.client:connect()
	elseif kind == "lastfmCancel" then
		self.client:cancelAuth()
	elseif kind == "lastfmOpenAuth" then
		if not self.client:openAuthPage() then
			self.toasts:show("Could not open a browser for Last.fm", "error")
		end
	elseif kind == "lastfmDisconnect" then
		self.client:disconnect()
	elseif kind == "lastfmEnabled" then
		self.settings.values.lastfmEnabled = message.value == true
		self.settings:changed()
	end
end

--- What playback has been doing since the last tick: a listen that reached the scrobbler's
--- threshold is sent, and what is playing is reported. Last.fm is busy while a request it started
--- is still out, which keeps the ticker at a frame rate until the answer arrives.
function Lastfm:step(_now)
	local changed = false
	local current = self.playback:current()
	local playing = self.playback.player:isPlaying()
	self.scrobbler:update(current, self.playback.player:position(), playing, os.time())
	if self.client:update(current, playing, self.scrobbler:take()) then changed = true end
	return changed, self.client:isBusy()
end

--- The libcurl handle goes when the app is set up again, so a test that makes many apps does not
--- keep one alive per app.
function Lastfm:close()
	self.client:close()
end

return Lastfm
