-- The messages the app delivers: clicks, what a screen asks for, what a service announces. Each
-- kind is a class with its own `type`, so a message is checked where it is written and a reader
-- sees the fields that kind carries. A message is made through these constructors rather than a
-- table literal, so its representation is this module's to change.
--
-- A plugin with a message of its own writes `messages.custom("its:type", { … })`; the payload is
-- kept whole for whatever answers it.
--- The fields every message may be written with. A message is read by kind, but a plugin's own
--- kind carries whatever it wants, so the base is open; a kind's own class adds the fields it
--- promises and a literal that leaves one out is still an error.
---@class beat.MessageFields: table<string, any>

---@class beat.NavigateMessage: beat.MessageFields
---@field type "navigate"
---@field page beat.Route
---@field keepFocus boolean?
---@class beat.OpenMessage: beat.MessageFields
---@field type "open"
---@field overlay string
---@field id number?
---@field kind "album"|"track"|string?
---@field menu string?
---@field name string?
---@field playlistId number?
---@field smart boolean?
---@field x number?
---@field y number?
---@class beat.DismissMessage: beat.MessageFields
---@field type "dismiss"
---@class beat.KeepMessage: beat.MessageFields
---@field type "keep"
---@class beat.BackMessage: beat.MessageFields
---@field type "back"
---@class beat.ForwardMessage: beat.MessageFields
---@field type "forward"
---@class beat.EscapeMessage: beat.MessageFields
---@field type "escape"
---@class beat.ResetMessage: beat.MessageFields
---@field type "reset"
---@field page beat.Route
---@class beat.FocusMessage: beat.MessageFields
---@field type "focus"
---@field field string
---@field at number?
---@class beat.PlayAlbumMessage: beat.MessageFields
---@field type "playAlbum"
---@field id number
---@field restart boolean?
---@field shuffle boolean?
---@class beat.PlayTrackMessage: beat.MessageFields
---@field type "playTrack"
---@field trackId number
---@field albumId number?
---@field artistId number?
---@field restart boolean?
---@class beat.PlayArtistMessage: beat.MessageFields
---@field type "playArtist"
---@field id number
---@class beat.PlayPlaylistMessage: beat.MessageFields
---@field type "playPlaylist"
---@field id number
---@field shuffle boolean?
---@class beat.PlayPlaylistTrackMessage: beat.MessageFields
---@field type "playPlaylistTrack"
---@field playlistId number
---@field trackId number
---@class beat.JumpTrackMessage: beat.MessageFields
---@field type "jumpTrack"
---@field trackId number
---@class beat.QueueAlbumMessage: beat.MessageFields
---@field type "queueAlbum"
---@field id number
---@field next boolean?
---@class beat.PlaylistAddAlbumMessage: beat.MessageFields
---@field type "playlistAddAlbum"
---@field id number
---@class beat.AddToPlaylistMessage: beat.MessageFields
---@field type "addToPlaylist"
---@field playlistId number
---@class beat.TogglePlayMessage: beat.MessageFields
---@field type "togglePlay"
---@class beat.NextMessage: beat.MessageFields
---@field type "next"
---@class beat.PreviousMessage: beat.MessageFields
---@field type "previous"
---@class beat.SeekMessage: beat.MessageFields
---@field type "seek"
---@field seconds number?
---@field by number?
---@class beat.VolumeMessage: beat.MessageFields
---@field type "volume"
---@field value number
---@class beat.MuteMessage: beat.MessageFields
---@field type "mute"
---@class beat.ShuffleMessage: beat.MessageFields
---@field type "shuffle"
---@class beat.RepeatMessage: beat.MessageFields
---@field type "repeat"
---@class beat.TrackStartedMessage: beat.MessageFields
---@field type "trackStarted"
---@field track beat.Track
---@field position number
---@class beat.TrackEndedMessage: beat.MessageFields
---@field type "trackEnded"
---@field track beat.Track
---@field completed boolean
---@class beat.QueueChangedMessage: beat.MessageFields
---@field type "queueChanged"
---@class beat.LibraryReplacedMessage: beat.MessageFields
---@field type "libraryReplaced"
---@class beat.LibraryChangedMessage: beat.MessageFields
---@field type "libraryChanged"
---@class beat.SearchMessage: beat.MessageFields
---@field type "search"
---@field value string
---@class beat.ClearSearchMessage: beat.MessageFields
---@field type "clearSearch"
---@class beat.OpenSearchMessage: beat.MessageFields
---@field type "openSearch"
---@class beat.ToggleTagFilterMessage: beat.MessageFields
---@field type "toggleTagFilter"
---@field id number
---@class beat.TagFilterMatchMessage: beat.MessageFields
---@field type "tagFilterMatch"
---@field value "all"|"any"
---@class beat.ClearTagFilterMessage: beat.MessageFields
---@field type "clearTagFilter"
---@class beat.ToggleTrackTagMessage: beat.MessageFields
---@field type "toggleTrackTag"
---@field id number
---@class beat.HoverTagMessage: beat.MessageFields
---@field type "hoverTag"
---@field id number?
---@class beat.HoverPlaylistMessage: beat.MessageFields
---@field type "hoverPlaylist"
---@field id number?
---@field y number
---@field x number?
---@field top number?
---@field height number?
---@class beat.ScrollMessage: beat.MessageFields
---@field type "scroll"
---@field key string
---@field max number?
---@field to number?
---@field by number?
---@class beat.SidebarWidthMessage: beat.MessageFields
---@field type "sidebarWidth"
---@field width number
---@class beat.ToggleSidebarMessage: beat.MessageFields
---@field type "toggleSidebar"
---@class beat.UiScaleMessage: beat.MessageFields
---@field type "uiScale"
---@field value number
---@class beat.ReduceMotionMessage: beat.MessageFields
---@field type "reduceMotion"
---@field value boolean
---@class beat.ThemeMessage: beat.MessageFields
---@field type "theme"
---@field name string
---@class beat.AccentMessage: beat.MessageFields
---@field type "accent"
---@field name string
---@class beat.ToggleViewMessage: beat.MessageFields
---@field type "toggleView"
---@class beat.SortMessage: beat.MessageFields
---@field type "sort"
---@field value string
---@class beat.ToastMessage: beat.MessageFields
---@field type "toast"
---@field text string
---@field tone string?
---@class beat.DismissToastMessage: beat.MessageFields
---@field type "dismissToast"
---@field at number
---@class beat.OpenURLMessage: beat.MessageFields
---@field type "openURL"
---@field url string
---@class beat.StartScanMessage: beat.MessageFields
---@field type "startScan"
---@field root string
---@class beat.RescanMessage: beat.MessageFields
---@field type "rescan"
---@class beat.ChooseFolderMessage: beat.MessageFields
---@field type "chooseFolder"
---@class beat.CancelScanMessage: beat.MessageFields
---@field type "cancelScan"
---@class beat.PickFolderMessage: beat.MessageFields
---@field type "pickFolder"
---@field reply string # The message type the chosen folder comes back as, with `path` nil when cancelled
---@field start string?
---@class beat.LibraryAddFolderMessage: beat.MessageFields
---@field type "libraryAddFolder"
---@field path string
---@class beat.HideScanIslandMessage: beat.MessageFields
---@field type "hideScanIsland"
---@class beat.ShowScanIslandMessage: beat.MessageFields
---@field type "showScanIsland"
---@class beat.DismissScanSummaryMessage: beat.MessageFields
---@field type "dismissScanSummary"
---@class beat.FolderUpMessage: beat.MessageFields
---@field type "folderUp"
---@class beat.FolderOpenMessage: beat.MessageFields
---@field type "folderOpen"
---@field path string
---@class beat.FolderSelectMessage: beat.MessageFields
---@field type "folderSelect"
---@field path string
---@class beat.FolderGoMessage: beat.MessageFields
---@field type "folderGo"
---@field path string
---@class beat.CancelFoldersMessage: beat.MessageFields
---@field type "cancelFolders"
---@class beat.OpenMenuMessage: beat.MessageFields
---@field type "open"
---@field overlay "menu"
---@field menu string
---@field id number
---@field x number?
---@field y number?
---@class beat.OpenPlaylistPickerMessage: beat.MessageFields
---@field type "open"
---@field overlay "playlist_picker"
---@field kind "album"|"track"
---@field id number
---@class beat.CreatePlaylistMessage: beat.MessageFields
---@field type "createPlaylist"
---@class beat.CreateTagMessage: beat.MessageFields
---@field type "createTag"
---@class beat.DeletePlaylistMessage: beat.MessageFields
---@field type "deletePlaylist"
---@field id number
---@class beat.DeleteTagMessage: beat.MessageFields
---@field type "deleteTag"
---@field id number
---@class beat.ConfirmDeleteTagMessage: beat.MessageFields
---@field type "confirmDeleteTag"
---@class beat.CancelDeleteTagMessage: beat.MessageFields
---@field type "cancelDeleteTag"
---@class beat.EditTagMessage: beat.MessageFields
---@field type "editTag"
---@field id number
---@class beat.RenameTagMessage: beat.MessageFields
---@field type "renameTag"
---@class beat.CancelTagEditMessage: beat.MessageFields
---@field type "cancelTagEdit"
---@class beat.TagDraftMessage: beat.MessageFields
---@field type "tagDraft"
---@field value string
---@class beat.TagEditDraftMessage: beat.MessageFields
---@field type "tagEditDraft"
---@field value string
---@class beat.PlaylistDraftMessage: beat.MessageFields
---@field type "playlistDraft"
---@field value string
---@class beat.PlaylistDraftTagMessage: beat.MessageFields
---@field type "playlistDraftTag"
---@field id number
---@class beat.PlaylistDraftMatchMessage: beat.MessageFields
---@field type "playlistDraftMatch"
---@field value "all"|"any"
---@class beat.PlaylistAdderQueryMessage: beat.MessageFields
---@field type "playlistAdderQuery"
---@field value string
---@class beat.EqualizerPresetMessage: beat.MessageFields
---@field type "equalizerPreset"
---@field id string
---@class beat.NewEqualizerPresetMessage: beat.MessageFields
---@field type "newEqualizerPreset"
---@class beat.EditEqualizerPresetMessage: beat.MessageFields
---@field type "editEqualizerPreset"
---@field name string
---@class beat.EqualizerGainMessage: beat.MessageFields
---@field type "equalizerGain"
---@field band number
---@field value number
---@class beat.SaveEqualizerPresetRenameMessage: beat.MessageFields
---@field type "saveEqualizerPresetRename"
---@field name string
---@field value string
---@class beat.CancelEqualizerPresetRenameMessage: beat.MessageFields
---@field type "cancelEqualizerPresetRename"
---@class beat.DeleteEqualizerPresetMessage: beat.MessageFields
---@field type "deleteEqualizerPreset"
---@field name string
---@class beat.EqualizerEditDraftMessage: beat.MessageFields
---@field type "equalizerEditDraft"
---@field value string
---@class beat.PickAccentMessage: beat.MessageFields
---@field type "pickAccent"
---@field value string
---@class beat.ConfirmAccentMessage: beat.MessageFields
---@field type "confirmAccent"
---@class beat.LastfmConnectMessage: beat.MessageFields
---@field type "lastfmConnect"
---@class beat.LastfmCancelMessage: beat.MessageFields
---@field type "lastfmCancel"
---@class beat.LastfmOpenAuthMessage: beat.MessageFields
---@field type "lastfmOpenAuth"
---@class beat.LastfmDisconnectMessage: beat.MessageFields
---@field type "lastfmDisconnect"
---@class beat.LastfmEnabledMessage: beat.MessageFields
---@field type "lastfmEnabled"
---@field value boolean
---@class beat.ExpandNowPlayingMessage: beat.MessageFields
---@field type "expandNowPlaying"
---@field open boolean
---@class beat.ToggleVolumeMessage: beat.MessageFields
---@field type "toggleVolume"
---@class beat.ToggleQueueMessage: beat.MessageFields
---@field type "toggleQueue"
---@class beat.ToggleMoreMessage: beat.MessageFields
---@field type "toggleMore"
---@class beat.ToggleEqualizerMessage: beat.MessageFields
---@field type "toggleEqualizer"
---@class beat.ProgressMessage: beat.MessageFields
---@field type "progress"
---@field phase "enumerate"|"inspect"
---@field files number
---@field inspected number
---@field tracks number
---@field skipped number
---@field errors { path: string, message: string }[]
---@field current string?
---@class beat.DoneMessage: beat.MessageFields
---@field type "done"
---@field inspected number?
---@field tracks number?
---@field skipped number?
---@field errors { path: string, message: string }[]?
---@class beat.CancelledMessage: beat.MessageFields
---@field type "cancelled"
---@class beat.InspectErrorMessage: beat.MessageFields
---@field type "error"
---@field message string
---@class beat.TrackMessage: beat.MessageFields
---@field type "track"
---@field info treble.audio.Inspect
---@field entry beat.ScanEntry
---@field cover string?
---@field coverCache string?
---@class beat.PluginSettingMessage: beat.MessageFields
---@field type "pluginSetting"
---@field plugin string
---@field key string
---@field value any
---@class beat.TaskCancelMessage: beat.MessageFields
---@field type "taskCancel"
---@field id number
---@class beat.TaskDismissMessage: beat.MessageFields
---@field type "taskDismiss"
---@field id number
---@class beat.CustomMessage: beat.MessageFields
---@field type string
---@field custom true

--- Every message the app knows, and a plugin's own kind through `custom`.
---@alias beat.Message
--- | beat.NavigateMessage
--- | beat.OpenMessage
--- | beat.DismissMessage
--- | beat.KeepMessage
--- | beat.BackMessage
--- | beat.ForwardMessage
--- | beat.EscapeMessage
--- | beat.ResetMessage
--- | beat.FocusMessage
--- | beat.PlayAlbumMessage
--- | beat.PlayTrackMessage
--- | beat.PlayArtistMessage
--- | beat.PlayPlaylistMessage
--- | beat.PlayPlaylistTrackMessage
--- | beat.JumpTrackMessage
--- | beat.QueueAlbumMessage
--- | beat.PlaylistAddAlbumMessage
--- | beat.AddToPlaylistMessage
--- | beat.TogglePlayMessage
--- | beat.NextMessage
--- | beat.PreviousMessage
--- | beat.SeekMessage
--- | beat.VolumeMessage
--- | beat.MuteMessage
--- | beat.ShuffleMessage
--- | beat.RepeatMessage
--- | beat.TrackStartedMessage
--- | beat.TrackEndedMessage
--- | beat.QueueChangedMessage
--- | beat.LibraryReplacedMessage
--- | beat.LibraryChangedMessage
--- | beat.SearchMessage
--- | beat.ClearSearchMessage
--- | beat.OpenSearchMessage
--- | beat.ToggleTagFilterMessage
--- | beat.TagFilterMatchMessage
--- | beat.ClearTagFilterMessage
--- | beat.ToggleTrackTagMessage
--- | beat.HoverTagMessage
--- | beat.HoverPlaylistMessage
--- | beat.ScrollMessage
--- | beat.SidebarWidthMessage
--- | beat.ToggleSidebarMessage
--- | beat.UiScaleMessage
--- | beat.ReduceMotionMessage
--- | beat.ThemeMessage
--- | beat.AccentMessage
--- | beat.ToggleViewMessage
--- | beat.SortMessage
--- | beat.ToastMessage
--- | beat.DismissToastMessage
--- | beat.OpenURLMessage
--- | beat.StartScanMessage
--- | beat.RescanMessage
--- | beat.ChooseFolderMessage
--- | beat.CancelScanMessage
--- | beat.PickFolderMessage
--- | beat.LibraryAddFolderMessage
--- | beat.HideScanIslandMessage
--- | beat.ShowScanIslandMessage
--- | beat.DismissScanSummaryMessage
--- | beat.FolderUpMessage
--- | beat.FolderOpenMessage
--- | beat.FolderSelectMessage
--- | beat.FolderGoMessage
--- | beat.CancelFoldersMessage
--- | beat.OpenMenuMessage
--- | beat.OpenPlaylistPickerMessage
--- | beat.CreatePlaylistMessage
--- | beat.CreateTagMessage
--- | beat.DeletePlaylistMessage
--- | beat.DeleteTagMessage
--- | beat.ConfirmDeleteTagMessage
--- | beat.CancelDeleteTagMessage
--- | beat.EditTagMessage
--- | beat.RenameTagMessage
--- | beat.CancelTagEditMessage
--- | beat.TagDraftMessage
--- | beat.TagEditDraftMessage
--- | beat.PlaylistDraftMessage
--- | beat.PlaylistDraftTagMessage
--- | beat.PlaylistDraftMatchMessage
--- | beat.PlaylistAdderQueryMessage
--- | beat.EqualizerPresetMessage
--- | beat.NewEqualizerPresetMessage
--- | beat.EditEqualizerPresetMessage
--- | beat.EqualizerGainMessage
--- | beat.SaveEqualizerPresetRenameMessage
--- | beat.CancelEqualizerPresetRenameMessage
--- | beat.DeleteEqualizerPresetMessage
--- | beat.EqualizerEditDraftMessage
--- | beat.PickAccentMessage
--- | beat.ConfirmAccentMessage
--- | beat.LastfmConnectMessage
--- | beat.LastfmCancelMessage
--- | beat.LastfmOpenAuthMessage
--- | beat.LastfmDisconnectMessage
--- | beat.LastfmEnabledMessage
--- | beat.ExpandNowPlayingMessage
--- | beat.ToggleVolumeMessage
--- | beat.ToggleQueueMessage
--- | beat.ToggleMoreMessage
--- | beat.ToggleEqualizerMessage
--- | beat.ProgressMessage
--- | beat.DoneMessage
--- | beat.CancelledMessage
--- | beat.InspectErrorMessage
--- | beat.TrackMessage
--- | beat.PluginSettingMessage
--- | beat.TaskCancelMessage
--- | beat.TaskDismissMessage
--- | beat.CustomMessage

--- What an overlay is opened with, beyond the overlay itself. A plugin registers its own overlay,
--- so the record is open; the fields the app's own screens pass are named here.
---@class beat.OpenFields: beat.MessageFields
---@field id number?
---@field kind "album"|"track"|string?
---@field menu string?
---@field name string?
---@field playlistId number?
---@field smart boolean?
---@field x number?
---@field y number?

--- What a scroll is asked for, beyond the key that names it.
---@class beat.ScrollFields: beat.MessageFields
---@field max number?
---@field to number?
---@field by number?

--- What a message of a plugin's own kind is made with: everything it carries, and the type that
--- names it.
---@class beat.CustomFields: table<string, any>

--- The constructors a plugin and the app's own screens write messages with. A helper returns the
--- message itself; handlers only ever read `type` and the fields they know.
---@class beat.Messages
---@field navigate fun(page: beat.Route, keepFocus: boolean?): beat.NavigateMessage
---@field open fun(overlay: string, fields: beat.OpenFields?): beat.OpenMessage
---@field openOverlay fun(overlay: string): beat.OpenMessage
---@field openMenu fun(menu: string, id: number, x: number?, y: number?): beat.OpenMenuMessage
---@field openPlaylistPicker fun(kind: "album"|"track", id: number): beat.OpenPlaylistPickerMessage
---@field openAlbum fun(id: number): beat.NavigateMessage
---@field openArtist fun(id: number): beat.NavigateMessage
---@field openPlaylist fun(id: number): beat.NavigateMessage
---@field openLibrary fun(): beat.NavigateMessage
---@field openHome fun(): beat.NavigateMessage
---@field dismiss fun(): beat.DismissMessage
---@field keep fun(): beat.KeepMessage
---@field back fun(): beat.BackMessage
---@field forward fun(): beat.ForwardMessage
---@field escape fun(): beat.EscapeMessage
---@field reset fun(page: beat.Route): beat.ResetMessage
---@field focus fun(field: string, at: number?): beat.FocusMessage
---@field playAlbum fun(id: number, restart: boolean?, shuffle: boolean?): beat.PlayAlbumMessage
---@field playTrack fun(trackId: number, albumId: number?, artistId: number?, restart: boolean?): beat.PlayTrackMessage
---@field playArtist fun(id: number): beat.PlayArtistMessage
---@field playPlaylist fun(id: number, shuffle: boolean?): beat.PlayPlaylistMessage
---@field playPlaylistTrack fun(playlistId: number, trackId: number): beat.PlayPlaylistTrackMessage
---@field jumpTrack fun(trackId: number): beat.JumpTrackMessage
---@field queueAlbum fun(id: number, next: boolean?): beat.QueueAlbumMessage
---@field togglePlay fun(): beat.TogglePlayMessage
---@field next fun(): beat.NextMessage
---@field previous fun(): beat.PreviousMessage
---@field seek fun(seconds: number): beat.SeekMessage
---@field seekBy fun(by: number): beat.SeekMessage
---@field volume fun(value: number): beat.VolumeMessage
---@field mute fun(): beat.MuteMessage
---@field shuffle fun(): beat.ShuffleMessage
---@field repeatPlay fun(): beat.RepeatMessage
---@field search fun(value: string): beat.SearchMessage
---@field clearSearch fun(): beat.ClearSearchMessage
---@field openSearch fun(): beat.OpenSearchMessage
---@field toggleTagFilter fun(id: number): beat.ToggleTagFilterMessage
---@field tagFilterMatch fun(value: "all"|"any"): beat.TagFilterMatchMessage
---@field clearTagFilter fun(): beat.ClearTagFilterMessage
---@field toggleTrackTag fun(id: number): beat.ToggleTrackTagMessage
---@field deletePlaylist fun(id: number): beat.DeletePlaylistMessage
---@field deleteTag fun(id: number): beat.DeleteTagMessage
---@field toast fun(text: string, tone: string?): beat.ToastMessage
---@field openURL fun(url: string): beat.OpenURLMessage
---@field pickFolder fun(reply: string, start: string?): beat.PickFolderMessage
---@field libraryAddFolder fun(path: string): beat.LibraryAddFolderMessage
---@field pluginSetting fun(plugin: string, key: string, value: any): beat.PluginSettingMessage
---@field taskCancel fun(id: number): beat.TaskCancelMessage
---@field taskDismiss fun(id: number): beat.TaskDismissMessage
---@field scroll fun(key: string, fields: beat.ScrollFields?): beat.ScrollMessage
---@field custom fun(kind: string, fields: beat.CustomFields?): beat.CustomMessage

local messages = {}

---@param page beat.Route
---@param keepFocus boolean?
---@return beat.NavigateMessage
function messages.navigate(page, keepFocus)
	return { type = "navigate", page = page, keepFocus = keepFocus }
end

---@param overlay string
---@param fields beat.OpenFields?
---@return beat.OpenMessage
function messages.open(overlay, fields)
	---@type beat.OpenMessage
	local message = { type = "open", overlay = overlay }
	for key, value in pairs(fields or {}) do message[key] = value end
	return message
end

---@param overlay string
---@return beat.OpenMessage
function messages.openOverlay(overlay)
	return { type = "open", overlay = overlay }
end

---@param menu string
---@param id number
---@param x number?
---@param y number?
---@return beat.OpenMenuMessage
function messages.openMenu(menu, id, x, y)
	return { type = "open", overlay = "menu", menu = menu, id = id, x = x, y = y }
end

---@param kind "album"|"track"
---@param id number
---@return beat.OpenPlaylistPickerMessage
function messages.openPlaylistPicker(kind, id)
	return { type = "open", overlay = "playlist_picker", kind = kind, id = id }
end

---@param id number
---@return beat.NavigateMessage
function messages.openAlbum(id) return { type = "navigate", page = { kind = "album", id = id } } end

---@param id number
---@return beat.NavigateMessage
function messages.openArtist(id) return { type = "navigate", page = { kind = "artist", id = id } } end

---@param id number
---@return beat.NavigateMessage
function messages.openPlaylist(id) return { type = "navigate", page = { kind = "playlist", id = id } } end

---@return beat.NavigateMessage
function messages.openLibrary() return { type = "navigate", page = { kind = "library" } } end

---@return beat.NavigateMessage
function messages.openHome() return { type = "navigate", page = { kind = "home" } } end

---@return beat.DismissMessage
function messages.dismiss() return { type = "dismiss" } end

---@return beat.KeepMessage
function messages.keep() return { type = "keep" } end

---@return beat.BackMessage
function messages.back() return { type = "back" } end

---@return beat.ForwardMessage
function messages.forward() return { type = "forward" } end

---@return beat.EscapeMessage
function messages.escape() return { type = "escape" } end

---@param page beat.Route
---@return beat.ResetMessage
function messages.reset(page) return { type = "reset", page = page } end

---@param field string
---@param at number?
---@return beat.FocusMessage
function messages.focus(field, at) return { type = "focus", field = field, at = at } end

---@param id number
---@param restart boolean?
---@param shuffle boolean?
---@return beat.PlayAlbumMessage
function messages.playAlbum(id, restart, shuffle)
	return { type = "playAlbum", id = id, restart = restart, shuffle = shuffle }
end

---@param trackId number
---@param albumId number?
---@param artistId number?
---@param restart boolean?
---@return beat.PlayTrackMessage
function messages.playTrack(trackId, albumId, artistId, restart)
	return { type = "playTrack", trackId = trackId, albumId = albumId, artistId = artistId, restart = restart }
end

---@param id number
---@return beat.PlayArtistMessage
function messages.playArtist(id) return { type = "playArtist", id = id } end

---@param id number
---@param shuffle boolean?
---@return beat.PlayPlaylistMessage
function messages.playPlaylist(id, shuffle) return { type = "playPlaylist", id = id, shuffle = shuffle } end

---@param playlistId number
---@param trackId number
---@return beat.PlayPlaylistTrackMessage
function messages.playPlaylistTrack(playlistId, trackId)
	return { type = "playPlaylistTrack", playlistId = playlistId, trackId = trackId }
end

---@param trackId number
---@return beat.JumpTrackMessage
function messages.jumpTrack(trackId) return { type = "jumpTrack", trackId = trackId } end

---@param id number
---@param next boolean?
---@return beat.QueueAlbumMessage
function messages.queueAlbum(id, next) return { type = "queueAlbum", id = id, next = next } end

---@return beat.TogglePlayMessage
function messages.togglePlay() return { type = "togglePlay" } end

---@return beat.NextMessage
function messages.next() return { type = "next" } end

---@return beat.PreviousMessage
function messages.previous() return { type = "previous" } end

---@param seconds number
---@return beat.SeekMessage
function messages.seek(seconds) return { type = "seek", seconds = seconds } end

---@param by number
---@return beat.SeekMessage
function messages.seekBy(by) return { type = "seek", by = by } end

---@param value number
---@return beat.VolumeMessage
function messages.volume(value) return { type = "volume", value = value } end

---@return beat.MuteMessage
function messages.mute() return { type = "mute" } end

---@return beat.ShuffleMessage
function messages.shuffle() return { type = "shuffle" } end

---@return beat.RepeatMessage
function messages.repeatPlay() return { type = "repeat" } end

---@param value string
---@return beat.SearchMessage
function messages.search(value) return { type = "search", value = value } end

---@return beat.ClearSearchMessage
function messages.clearSearch() return { type = "clearSearch" } end

---@return beat.OpenSearchMessage
function messages.openSearch() return { type = "openSearch" } end

---@param id number
---@return beat.ToggleTagFilterMessage
function messages.toggleTagFilter(id) return { type = "toggleTagFilter", id = id } end

---@param value "all"|"any"
---@return beat.TagFilterMatchMessage
function messages.tagFilterMatch(value) return { type = "tagFilterMatch", value = value } end

---@return beat.ClearTagFilterMessage
function messages.clearTagFilter() return { type = "clearTagFilter" } end

---@param id number
---@return beat.ToggleTrackTagMessage
function messages.toggleTrackTag(id) return { type = "toggleTrackTag", id = id } end

---@param id number
---@return beat.DeletePlaylistMessage
function messages.deletePlaylist(id) return { type = "deletePlaylist", id = id } end

---@param id number
---@return beat.DeleteTagMessage
function messages.deleteTag(id) return { type = "deleteTag", id = id } end

---@param text string
---@param tone string?
---@return beat.ToastMessage
function messages.toast(text, tone) return { type = "toast", text = text, tone = tone } end

---@param url string
---@return beat.OpenURLMessage
function messages.openURL(url) return { type = "openURL", url = url } end

---@param key string
---@param fields beat.ScrollFields?
---@return beat.ScrollMessage
function messages.scroll(key, fields)
	---@type beat.ScrollMessage
	local message = { type = "scroll", key = key }
	for field, value in pairs(fields or {}) do message[field] = value end
	return message
end

---@param reply string
---@param start string?
---@return beat.PickFolderMessage
function messages.pickFolder(reply, start) return { type = "pickFolder", reply = reply, start = start } end

---@param path string
---@return beat.LibraryAddFolderMessage
function messages.libraryAddFolder(path) return { type = "libraryAddFolder", path = path } end

---@param plugin string
---@param key string
---@param value any
---@return beat.PluginSettingMessage
function messages.pluginSetting(plugin, key, value)
	return { type = "pluginSetting", plugin = plugin, key = key, value = value }
end

---@param id number
---@return beat.TaskCancelMessage
function messages.taskCancel(id) return { type = "taskCancel", id = id } end

---@param id number
---@return beat.TaskDismissMessage
function messages.taskDismiss(id) return { type = "taskDismiss", id = id } end

---@param kind string
---@param fields beat.CustomFields?
---@return beat.CustomMessage
function messages.custom(kind, fields)
	local message = fields or {}
	message.type, message.custom = kind, true
	return message
end

return messages
