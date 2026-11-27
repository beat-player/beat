-- The equalizer: the five bands, the shapes they can take and the presets this person saved, and
-- the one place that tells the audio player what they are. It is a service of its own rather than
-- a part of playback because shaping the sound is a deliberate act -- the transport never asks --
-- and because what it remembers is settings that outlive every track. The band and preset numbers
-- are in `bands.lua` beside this file: the service owns the rules, the panel only draws them.
local fs = require("fs")
local path = require("path")
local bands = require("beat.app.services.equalizer.bands")
local autoeq = require("beat.app.services.equalizer.autoeq")
local Picker = require("beat.app.services.scan.picker")

---@class beat.EqualizerService: beat.Service
---@field frequencies number[]
---@field labels string[]
---@field minimum number
---@field maximum number
---@field preampMinimum number
---@field preampMaximum number
---@field curveMinimum number # The lowest frequency the response is sampled at
---@field curveMaximum number # And the highest
---@field settings beat.SettingsService
---@field playback beat.PlaybackService
---@field toasts beat.ToastsService
---@field emit fun(message: table)
---@field window fun(): winit.Window?
---@field pick beat.FolderPick? # The profile file dialog, while it is open
---@field bandTable treble.Equalizer.Band[]? # What the player was last given, preamp included
---@field curveValues number[]? # The response the panel draws, made with the bands
---@field presetsCache beat.EqualizerService.PresetsCache? # The panel's list, kept until a saved preset changes
local Equalizer = {}
Equalizer.__index = Equalizer
Equalizer.needs = { "settings", "playback", "toasts", "emit", "window" }

-- How many presets the panel's add button will make. A file that already holds more is left alone
-- on load, because refusing them would throw away shapes someone saved deliberately.
local CUSTOM_LIMIT = 8

-- What a loaded file is allowed to hand the panel: the same cap the settings model used to apply.
local LOAD_LIMIT = 32

-- How often a dialog that is still open is asked for its answer. It is a file check, not a frame
-- of work, and the native chooser is on a thread of its own.
local PICK_INTERVAL = 0.25

---@param deps {
--- settings: beat.SettingsService,
--- playback: beat.PlaybackService,
--- toasts: beat.ToastsService,
--- emit: fun(message: table),
--- window: fun(): winit.Window?,
--- }
---@return beat.EqualizerService
function Equalizer.new(deps)
	local self = setmetatable({
		-- The panel needs the bands it draws; going through one place keeps its sliders and the
		-- player's bands from disagreeing about order or count.
		frequencies = bands.frequencies,
		labels = bands.labels,
		minimum = bands.minimum,
		maximum = bands.maximum,
		preampMinimum = bands.preampMinimum,
		preampMaximum = bands.preampMaximum,
		curveMinimum = bands.curveMinimum,
		curveMaximum = bands.curveMaximum,
		settings = deps.settings,
		playback = deps.playback,
		toasts = deps.toasts,
		emit = deps.emit,
		window = deps.window,
		pick = nil,
		bandTable = nil,
		curveValues = nil,
		presetsCache = nil
	}, Equalizer)

	self:load()
	self:apply()

	return self
end

--- What the settings file held is a hint, not a promise: a hand-edited file can hold any gain, a
--- preset that no longer exists under a name, or the same custom name twice. Every gain is held to
--- the range, custom presets that repeat a built-in or each other are dropped, and a preset that is
--- gone falls back to the custom gains that were stored or to Flat -- the same reading the settings
--- model did when it owned these keys. The result is written straight back, so the first save on
--- disk is clean again.
function Equalizer:load()
	local values = self.settings.values
	local preset = type(values.equalizerPreset) == "string" and values.equalizerPreset or "flat"
	local customs = {}
	local used = {}
	for _, builtin in ipairs(bands.presets) do
		used[builtin.name] = true
		used[builtin.id] = true
	end
	if type(values.equalizerCustomPresets) == "table" then
		for _, item in ipairs(values.equalizerCustomPresets) do
			if type(item) == "table" and type(item.name) == "string" and item.name ~= "" and not used[item.name] and #customs < LOAD_LIMIT then
				customs[#customs + 1] = { name = item.name, gains = bands.sanitize(item.gains) }
				used[item.name] = true
			end
		end
	end
	local custom
	for _, entry in ipairs(customs) do
		if preset == entry.name then custom = entry end
	end
	local gains = values.equalizerGains ~= nil and bands.sanitize(values.equalizerGains) or (custom ~= nil and bands.copyGains(
		custom.gains
	)) or bands.presetGains(preset)
	if bands.preset(preset) == nil and custom == nil then
		preset = type(values.equalizerGains) == "table" ? "custom" : "flat"
	end

	values.equalizerPreset = preset
	values.equalizerGains = gains
	values.equalizerCustomPresets = customs
	-- The fader's preamp and the imported profile follow the same rule: read once, held to what the
	-- player can take, and written back so the next save is already clean.
	values.equalizerPreamp = bands.clampPreamp(values.equalizerPreamp)
	values.equalizerProfile = autoeq.sanitize(values.equalizerProfile)
end

--- The bank the audio player is given. Called at start and after every change, so what sounds is
--- always the selection the panel shows: the five faders, the imported profile's filters under
--- them and the preamp the two add up to. The curve is made here as well, once per change, because
--- it is the same bank the player is hearing -- a frame only plots it.
function Equalizer:apply()
	local values = self.settings.values
	local bank = bands.combine(values.equalizerGains, values.equalizerPreamp, values.equalizerProfile)
	self.bandTable = bank
	self.curveValues = bands.response(bank)
	self.playback.player:setEqualizer(bank)
end

-- ────────────────────────────────────────────────────────────────
-- what the panel draws
-- ────────────────────────────────────────────────────────────────

-- Settings has no revision of its own, so the cached list keeps the settings records it was made
-- from: the table, its length and each record's identity say whether a preset was added or removed,
-- and a name or a gain edited in place is copied onto the wrapper before it is handed back. The
-- panel reads this list on every frame, so the check costs comparisons and the rebuild only a
-- changed list.
local NO_CUSTOMS = {}

---@class beat.EqualizerService.PresetsCache
---@field customs table[]
---@field count number
---@field entries beat.EqualizerPreset[] # The saved presets' wrappers, by that order
---@field list beat.EqualizerPreset[]

--- The built-in shapes and the ones this person has saved, in the order the panel draws them.
---@return beat.EqualizerPreset[]
function Equalizer:presets()
	local customs = self.settings.values.equalizerCustomPresets
	if type(customs) ~= "table" then customs = NO_CUSTOMS end
	local count = #customs

	local kept = self.presetsCache
	if kept ~= nil and kept.customs == customs and kept.count == count then
		local entries = kept.entries
		local fresh = true
		for at = 1, count do
			local source = customs[at]
			local entry = entries[at]
			if entry.source ~= source then
				fresh = false
				break
			end
			-- A rename or an edit changes the record in place: the wrapper points at what it now
			-- holds rather than making the panel rebuild its list.
			entry.id = source.name
			entry.name = source.name
			entry.gains = source.gains
		end
		if fresh then return kept.list end
	end

	local list = {}
	local builtins = bands.presets
	for at = 1, #builtins do list[#list + 1] = builtins[at] end
	local entries = {}
	for at = 1, count do
		local preset = customs[at]
		local entry = { id = preset.name, name = preset.name, gains = preset.gains, custom = true, source = preset }
		list[#list + 1] = entry
		entries[#entries + 1] = entry
	end
	self.presetsCache = { customs = customs, count = count, entries = entries, list = list }
	return list
end

--- A preset by its id, which for a saved one is its name.
---@param id string?
---@return beat.EqualizerPreset?
function Equalizer:find(id)
	if id == nil then return nil end
	for _, preset in ipairs(self:presets()) do
		if preset.id == id then return preset end
	end
	return nil
end

--- The id of the shape the bands currently are, for the panel to mark it.
---@return string
function Equalizer:selected()
	return self.settings.values.equalizerPreset or "flat"
end

--- The five gains the panel's faders show.
---@return number[]
function Equalizer:gains()
	return self.settings.values.equalizerGains or {}
end

--- The preamp fader's own value, before the profile's correction is added.
---@return number
function Equalizer:preamp()
	return self.settings.values.equalizerPreamp or 0
end

---@return beat.EqualizerProfile?
function Equalizer:profile()
	return self.settings.values.equalizerProfile
end

--- The response the panel draws, sampled when the bank last changed.
---@return number[]
function Equalizer:curve()
	return self.curveValues or {}
end

--- The bank itself: the fader bands, the profile's filters and the preamp. The panel does not
--- draw it, but a caller asking what the player was told reads it here.
---@return treble.Equalizer.Band[]
function Equalizer:bank()
	return self.bandTable or {}
end

-- ────────────────────────────────────────────────────────────────
-- the preamp and the imported profile
-- ────────────────────────────────────────────────────────────────

--- The fader's preamp. It does not change which preset is selected: the profile and the correction
--- are about the level, not the shape, and a preset's gains are still the bands a person chose.
---@param value number?
function Equalizer:setPreamp(value)
	local values = self.settings.values
	values.equalizerPreamp = bands.clampPreamp(value)
	self:apply()
	self.settings:changed()
end

--- Stores a parsed profile under the faders and makes it heard. The profile is cleaned once more
--- here rather than trusted: a caller with a table it built itself goes through the same rules a
--- picked file does.
---@param profile beat.EqualizerProfile?
function Equalizer:store(profile)
	local clean = autoeq.sanitize(profile)
	if clean == nil then
		self.toasts:show("That profile has no bands to import", "error")
		return
	end
	self.settings.values.equalizerProfile = clean
	self:apply()
	self.settings:changed()
end

---@param file string
function Equalizer:importFile(file)
	local text = fs.read(file)
	if text == nil then
		self.toasts:show("Could not read that profile", "error")
		return
	end
	local profile = autoeq.parse(text)
	if profile == nil then
		self.toasts:show("That file is not an EqualizerAPO profile", "error")
		return
	end

	-- The file name without its extension is the name the chip shows: it is what a person chose in
	-- the dialog and what AutoEq named the model.
	local name = path.basename(file)
	local extension = path.extension(file)
	if extension ~= "" then name = name:sub(1, #name - #extension - 1) end
	name = name:match("^%s*(.-)%s*$")
	profile.name = name ~= "" and name or "Imported profile"
	self:store(profile)
end

---@param text string?
function Equalizer:importText(text)
	if type(text) ~= "string" or text:find("%S") == nil then
		self.toasts:show("The clipboard has no profile text", "error")
		return
	end
	local profile = autoeq.parse(text)
	if profile == nil then
		self.toasts:show("That does not look like an EqualizerAPO profile", "error")
		return
	end
	profile.name = "Pasted profile"
	self:store(profile)
end

--- Opens the system file dialog. The answer is read in `step`, like the folder picker's: on
--- Linux the chooser runs on a worker thread, and on the other platforms the modal call has
--- already returned by the time this function does.
function Equalizer:pickProfile()
	if self.pick ~= nil then return end
	self.pick = Picker.startFile(self.window(), {
		title = "Choose equalizer profile",
		filters = { { name = "EqualizerAPO profile", extensions = { "txt" } } }
	})
end

--- Drops the imported profile, leaving the five faders and the fader's preamp as they were.
function Equalizer:clearProfile()
	if self.settings.values.equalizerProfile == nil then return end
	self.settings.values.equalizerProfile = nil
	self:apply()
	self.settings:changed()
end

--- Reads the file dialog's answer once it is written. A dialog left open or one this platform does
--- not have reports through the status `poll` gives, the same way a folder pick does.
---@param _now number
---@return boolean? changed
---@return number? busy
function Equalizer:step(_now)
	if self.pick == nil then return nil end
	local chosen, status = Picker.poll(self.pick)
	if chosen ~= nil then
		self.pick = nil
		self:importFile(chosen)
		return true
	elseif status ~= nil then
		self.pick = nil
		if status == "no-picker" then
			self.toasts:show("No system file dialog is available on this machine", "error")
		end
		return true
	end
	-- Still open: a file check four times a second, not a frame of work.
	return nil, PICK_INTERVAL
end

-- ────────────────────────────────────────────────────────────────
-- the rules
-- ────────────────────────────────────────────────────────────────

--- The name a new preset gets: "Custom", then "Custom 2" and so on, so a name someone types later
--- is the only way the list can collide.
---@return string
function Equalizer:nextName()
	local used = {}
	for _, preset in ipairs(self:presets()) do used[preset.name] = true end
	local name = "Custom"
	local number = 2
	while used[name] do
		name = "Custom " .. tostring(number)
		number += 1
	end
	return name
end

--- Whether a saved name can become another: the old one does not clash with itself.
---@param oldName string
---@param newName string
---@return boolean
function Equalizer:nameFree(oldName, newName)
	for _, preset in ipairs(self:presets()) do
		if preset.name == newName and preset.name ~= oldName then return false end
	end
	return true
end

--- Choosing a shape replaces the bands with the shape's gains and remembers both. An id that no
--- longer exists -- a saved preset deleted from another window -- changes nothing.
---@param id string?
function Equalizer:select(id)
	local preset = self:find(id)
	if preset == nil then return end
	local values = self.settings.values
	values.equalizerPreset = preset.id
	values.equalizerGains = bands.copyGains(preset.gains)
	self:apply()
	self.settings:changed()
end

--- Saving the bands as they are now. The panel stops at eight so its chips keep fitting; an
--- answer rather than a silent no-op, because pressing add and seeing nothing is worse.
function Equalizer:create()
	local values = self.settings.values
	local customs = values.equalizerCustomPresets or {}
	if #customs >= CUSTOM_LIMIT then
		self.toasts:show("That is enough custom presets for now", "error")
		return
	end
	local name = self:nextName()
	local gains = bands.copyGains(values.equalizerGains or {})
	values.equalizerCustomPresets = customs
	customs[#customs + 1] = { name = name, gains = gains }
	values.equalizerPreset = name
	self:apply()
	self.settings:changed()
end

--- A fader. Moving it inside a saved preset edits that preset; moving it from a built-in shape
--- makes a one-off `custom` selection rather than quietly changing the shape everyone has.
---@param band number?
---@param value number?
function Equalizer:setGain(band, value)
	if type(band) ~= "number" or band < 1 or band > #self.frequencies then return end
	local values = self.settings.values
	local gains = bands.sanitize(values.equalizerGains or {})
	gains[band] = bands.clamp(value or 0)
	local selected = self:find(values.equalizerPreset)
	if selected?.custom then
		for _, preset in ipairs(values.equalizerCustomPresets or {}) do
			if preset.name == selected.id then preset.gains = bands.copyGains(gains) end
		end
	else
		values.equalizerPreset = "custom"
	end
	values.equalizerGains = gains
	self:apply()
	self.settings:changed()
end

--- Renaming a saved preset. The draft is trimmed here because that is what a saved name is; an
--- empty or already used name is refused with the toast the dialog has always shown, rather than
--- a dialog that appears to save and does not.
---@param oldName string
---@param newName string?
---@return boolean
function Equalizer:rename(oldName, newName)
	local wanted = (newName or ""):match("^%s*(.-)%s*$")
	if wanted == "" then
		self.toasts:show("Choose a preset name", "error")
		return false
	end
	if not self:nameFree(oldName, wanted) then
		self.toasts:show("Choose a preset name that is not already used", "error")
		return false
	end
	local values = self.settings.values
	local found
	for _, preset in ipairs(values.equalizerCustomPresets or {}) do
		if preset.name == oldName then found = preset end
	end
	if found == nil then return false end
	found.name = wanted
	if values.equalizerPreset == oldName then values.equalizerPreset = wanted end
	self.settings:changed()
	return true
end

--- Deleting a saved preset. Deleting the selected one falls back to Flat, the shape that is always
--- there, and the player hears that immediately.
---@param name string?
---@return boolean
function Equalizer:delete(name)
	local values = self.settings.values
	---@type number?
	local at
	local customs = values.equalizerCustomPresets or {}
	for index, preset in ipairs(customs) do
		if preset.name == name then
			at = index
			break
		end
	end
	if at == nil then return false end
	table.remove(customs, at)
	if values.equalizerPreset == name then
		values.equalizerPreset = "flat"
		values.equalizerGains = bands.presetGains("flat")
		self:apply()
	end
	self.settings:changed()
	return true
end

-- ────────────────────────────────────────────────────────────────
-- the messages
-- ────────────────────────────────────────────────────────────────

--- Double-clicking a saved preset asks for the dialog that renames or deletes it. A built-in shape
--- has no such dialog: there is nothing about it this person owns.
---@param name string?
function Equalizer:edit(name)
	local preset = self:find(name)
	if preset == nil or not preset.custom then return end
	self.emit({ type = "open", overlay = "equalizer_rename", name = preset.name })
end

--- The rename dialog closes itself when it is cancelled or its backdrop is pressed; a save or a
--- delete that went through closes it from here, because whether the name was good enough to keep
--- is a rule of this service rather than a question the view can answer.
function Equalizer:closeDialog()
	self.emit({ type = "dismiss" })
end

--- The panel's controls and the dialogs they open.
Equalizer.on = {
	--- A preset chip in the panel. An id that no longer exists changes nothing, so the chip for a
	--- preset deleted from another window is harmless.
	---@param self beat.EqualizerService
	---@param message beat.EqualizerPresetMessage
	equalizerPreset = function(self, message) self:select(message.id) end,

	---@param self beat.EqualizerService
	---@param message beat.NewEqualizerPresetMessage
	newEqualizerPreset = function(self, message) self:create() end,

	---@param self beat.EqualizerService
	---@param message beat.EditEqualizerPresetMessage
	editEqualizerPreset = function(self, message) self:edit(message.name) end,

	---@param self beat.EqualizerService
	---@param message beat.EqualizerGainMessage
	equalizerGain = function(self, message) self:setGain(message.band, message.value) end,

	---@param self beat.EqualizerService
	---@param message beat.EqualizerPreampMessage
	equalizerPreamp = function(self, message) self:setPreamp(message.value) end,

	--- The two ways a profile arrives. A picked file is opened by the system and read on the next
	--- tick; pasted text is already here, so it is parsed at once.
	---@param self beat.EqualizerService
	---@param message beat.ImportEqualizerProfileMessage
	equalizerImportFile = function(self, message) self:pickProfile() end,

	---@param self beat.EqualizerService
	---@param message beat.PasteEqualizerProfileMessage
	equalizerImportText = function(self, message) self:importText(message.text) end,

	---@param self beat.EqualizerService
	---@param message beat.ClearEqualizerProfileMessage
	equalizerClearProfile = function(self, message) self:clearProfile() end,

	--- A refused name leaves the dialog open, so the one that went through closes it from here.
	---@param self beat.EqualizerService
	---@param message beat.SaveEqualizerPresetRenameMessage
	saveEqualizerPresetRename = function(self, message)
		if self:rename(message.name, message.value) then self:closeDialog() end
	end,

	---@param self beat.EqualizerService
	---@param message beat.DeleteEqualizerPresetMessage
	deleteEqualizerPreset = function(self, message)
		if self:delete(message.name) then self:closeDialog() end
	end
}

return Equalizer
