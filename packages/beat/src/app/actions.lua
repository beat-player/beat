-- What a message does when no overlay and not the page took it: the things more than one screen
-- asks for -- going somewhere, opening a panel, scrolling, a toast. Each is a function of the app
-- and the message, keyed by the message's type.
local wonderland = require("wonderland")
local core = require("beat-core")
local Picker = require("beat.app.picker")

local time = wonderland.time
local util = core.util

---@type table<string, fun(app: beat.App, message: table)>
local actions = {}

function actions.navigate(app, message)
	app:go(message.page)
end

function actions.back(app)
	app:back()
end

function actions.forward(app)
	app:forward()
end

--- `{ type = "open", overlay = "track_menu", ... }`: the rest of the message is what the overlay
--- is opened with.
function actions.open(app, message)
	app:open(message.overlay, message)
end

--- A box that scrolls by itself names its key and how far it goes; anything else is the page.
function actions.scroll(app, message)
	local key = message.key or app:pageKey()
	local offset = app.scroll[key] or 0
	local limit = message.key ~= nil and message.max or app.scrollMax
	---@param value number
	local function clampScroll(value)
		value = math.max(0, value)
		return limit ~= nil and math.min(value, limit) or value
	end
	if message.to ~= nil then
		-- A bar dragged is already where the pointer put it: chasing it would make the thumb lag
		-- the hand moving it.
		offset = clampScroll(message.to --[[@as number]])
		app.scroll[key] = offset
		app.scrollTargets[key] = offset
		app.scrollAnimating = false
		app:refresh()
	else
		app.scroll[key] = offset
		app.scrollTargets[key] = clampScroll(
		(app.scrollTargets[key] or offset) + (message.by --[[@as number?]] or 0) * app.theme:px(60))
		app.scrollAnimating = true
		-- Start the easing clock now, then wake the ticker for the next frame instead of drawing
		-- once per wheel event.
		app.lastTick = time.now()
		app:wake()
	end
end

function actions.toast(app, message)
	app:toast(message.text or "", message.tone)
end

function actions.dismissToast(app, message)
	for at = #app.toasts, 1, -1 do
			if app.toasts[at].at == message.at then table.remove(app.toasts, at) end
		end
end

--- The search field is the app's, because the top bar is: typing in it from any page goes to the
--- search page rather than to the page under the bar.
function actions.search(app, message)
	app.search = message.value or ""
	if app.page.kind ~= "search" then
		---@type beat.Route
		local page = { kind = "search"}
		-- The search field started this navigation. It keeps the keyboard and its caret, so
		-- the next character is typed after the first rather than put in front of it.
		app:go(page, true)
	else
		app:refresh()
	end
end

function actions.playAlbum(app, message)
	local album = app.library and app.library:album(message.id --[[@as number]])
	if album ~= nil then
		local current = app.player:current()
		if not message.shuffle and current ~= nil and current.albumId == album.id then
			app.player:toggle()
		elseif message.shuffle then
			app.player:playTracks(album.tracks, 1, { shuffle = true, source = "album"})
		else
			app.player:playAlbum(album)
		end
	end
end

function actions.playTrack(app, message)
	local track = app.library and app.library:track(message.trackId)
	local tracks = nil
	if message.albumId ~= nil and app.library ~= nil then
		local album = app.library:album(message.albumId --[[@as number]])
		tracks = album and album.tracks
	elseif message.artistId ~= nil and app.library ~= nil then
		local artist = app.library:artist(message.artistId --[[@as number]])
		tracks = artist and artist.tracks
	end
	local current = app.player:current()
	if track ~= nil and current ~= nil and current.id == track.id then
		app.player:toggle()
	elseif track ~= nil then
		app.player:playTrack(track, tracks)
	end
end

function actions.togglePlay(app)
	if app.player.queue == nil then
		if app.page.kind == "album" and app.library ~= nil then
			local album = app.library:album(app.page.id)
			if album ~= nil then app.player:playAlbum(album) end
		elseif app.library ~= nil and #app.library.tracks > 0 then
			app.player:playTracks(app.library.tracks, 1, { source = "library"})
		end
	else
		app.player:toggle()
	end
end

function actions.next(app)
	app.player:next()
end

function actions.previous(app)
	app.player:previous()
end

function actions.seek(app, message)
	app.player:seek(message.seconds or 0)
end

function actions.volume(app, message)
	app.settings.volume = util.clamp(message.value or 0, 0, 1)
	app.settings.isMuted = false
	app.player.isMuted = false
	app.player:setVolume(app.settings.volume)
	app:markSettingsDirty()
end

function actions.mute(app)
	app.settings.isMuted = app.player:toggleMute()
	app:markSettingsDirty()
end

function actions.shuffle(app)
	local queue = app.player.queue
	if queue ~= nil then app.player:setShuffle(not queue.shuffle) end
end

actions["repeat"] = function(app)
	app.player:cycleRepeat()
end

function actions.chooseFolder(app)
	if app.folderPick == nil then
		app.folderPick = Picker.start(app.window)
	end
end

function actions.cancelScan(app)
	if app.scan ~= nil then
		app.scan:cancel()
		app.scan = nil
		app.scanIslandOpen = false
		app:toast("Scan cancelled")
		app:refresh()
	end
end

function actions.hideScanIsland(app)
	app.scanIslandOpen = false
	app:refresh()
end

function actions.showScanIsland(app)
	app.scanIslandOpen = true
	app:refresh()
end

function actions.dismissScanSummary(app)
	app.scanSummary = nil
	app:refresh()
end

--- The tooltip belongs to the row under the pointer, so it is kept where the row put it: this is
--- a frame's hit test answering, not a screen deciding what to draw.
function actions.hoverPlaylist(app, message)
	local id = tonumber(message.id)
	local playlist = id ~= nil and app.taxonomy ~= nil and app.taxonomy:playlist(id) or nil
	if playlist == nil then
		app.hoverPlaylist = nil
	else
		local y = tonumber(message.y) or 0
		local top = tonumber(message.top)
		local x = tonumber(message.x)
		local height = tonumber(message.height)
		local old = app.hoverPlaylist
		if old == nil or old.id ~= id or old.y ~= y or old.top ~= top
		or old.x ~= x or old.height ~= height then
			app.hoverPlaylist = {
			id = id --[[@as number]], y = y, top = top, x = x, height = height,
			}
		end
	end
end

function actions.sidebarWidth(app, message)
	app.settings.sidebarWidth = util.clamp(message.width or 264, 200, 360)
	app:markSettingsDirty()
	app:refresh()
end

function actions.toggleSidebar(app)
	app.settings.sidebarCollapsed = not app.settings.sidebarCollapsed
	app:markSettingsDirty()
	app:refresh()
end

return actions
