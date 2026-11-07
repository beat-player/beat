-- The equalizer: the five bands, the shapes they can take and the presets this person saved, and
-- the one place that tells the audio player what they are. It is a service of its own rather than
-- a part of playback because shaping the sound is a deliberate act -- the transport never asks --
-- and because what it remembers is settings that outlive every track. The band and preset numbers
-- are in `bands.lua` beside this file: the service owns the rules, the panel only draws them.
local bands = require("beat.app.services.equalizer.bands")

---@class beat.EqualizerService
---@field frequencies number[]
---@field labels string[]
---@field minimum number
---@field maximum number
---@field settings beat.SettingsService
---@field playback beat.PlaybackService
---@field toasts beat.ToastsService
---@field emit fun(message: table)
local Equalizer = {}
Equalizer.__index = Equalizer
Equalizer.needs = { "settings", "playback", "toasts", "emit" }
Equalizer.handles = {
	"equalizerPreset", "newEqualizerPreset", "editEqualizerPreset", "equalizerGain",
	"saveEqualizerPresetRename", "deleteEqualizerPreset",
}

-- How many presets the panel's add button will make. A file that already holds more is left alone
-- on load, because refusing them would throw away shapes someone saved deliberately.
local CUSTOM_LIMIT = 8

-- What a loaded file is allowed to hand the panel: the same cap the settings model used to apply.
local LOAD_LIMIT = 32

---@param deps {
--- settings: beat.SettingsService,
--- playback: beat.PlaybackService,
--- toasts: beat.ToastsService,
--- emit: fun(message: table),
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
		settings = deps.settings,
		playback = deps.playback,
		toasts = deps.toasts,
		emit = deps.emit,
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
			if type(item) == "table" and type(item.name) == "string" and item.name ~= ""
			and not used[item.name] and #customs < LOAD_LIMIT then
				customs[#customs + 1] = { name = item.name, gains = bands.sanitize(item.gains)}
				used[item.name] = true
			end
		end
	end
	local custom
	for _, entry in ipairs(customs) do
		if preset == entry.name then custom = entry end
	end
	local gains = values.equalizerGains ~= nil and bands.sanitize(values.equalizerGains)
	or (custom ~= nil and bands.copyGains(custom.gains)) or bands.presetGains(preset)
	if bands.preset(preset) == nil and custom == nil then
		preset = type(values.equalizerGains) == "table" and "custom" or "flat"
	end

	values.equalizerPreset = preset
	values.equalizerGains = gains
	values.equalizerCustomPresets = customs
end

--- The bands the audio player is given. Called at start and after every change, so what sounds is
--- always the selection the panel shows.
function Equalizer:apply()
	self.playback.player:setEqualizer(bands.bands(self.settings.values.equalizerGains))
end

-- ────────────────────────────────────────────────────────────────
-- what the panel draws
-- ────────────────────────────────────────────────────────────────

--- The built-in shapes and the ones this person has saved, in the order the panel draws them.
---@return beat.EqualizerPreset[]
function Equalizer:presets()
	local list = {}
	for _, preset in ipairs(bands.presets) do list[#list + 1] = preset end
	for _, preset in ipairs(self.settings.values.equalizerCustomPresets) do
		list[#list + 1] = {
			id = preset.name,
			name = preset.name,
			gains = preset.gains,
			custom = true,
		}
	end
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
	return self.settings.values.equalizerPreset
end

--- The five gains the panel's faders show.
---@return number[]
function Equalizer:gains()
	return self.settings.values.equalizerGains
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
		number = number + 1
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
	if #values.equalizerCustomPresets >= CUSTOM_LIMIT then
		self.toasts:show("That is enough custom presets for now", "error")
		return
	end
	local name = self:nextName()
	local gains = bands.copyGains(values.equalizerGains)
	values.equalizerCustomPresets[#values.equalizerCustomPresets + 1] = {
		name = name,
		gains = gains,
	}
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
	local gains = bands.sanitize(values.equalizerGains)
	gains[band] = bands.clamp(value or 0)
	local selected = self:find(values.equalizerPreset)
	if selected ~= nil and selected.custom then
		for _, preset in ipairs(values.equalizerCustomPresets) do
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
	for _, preset in ipairs(values.equalizerCustomPresets) do
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
	local at
	for index, preset in ipairs(values.equalizerCustomPresets) do
		if preset.name == name then at = index; break end
	end
	if at == nil then return false end
	table.remove(values.equalizerCustomPresets, at)
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

function Equalizer:update(message)
	local kind = message.type
	if kind == "equalizerPreset" then
		self:select(message.id)
	elseif kind == "newEqualizerPreset" then
		self:create()
	elseif kind == "editEqualizerPreset" then
		self:edit(message.name)
	elseif kind == "equalizerGain" then
		self:setGain(message.band, message.value)
	elseif kind == "saveEqualizerPresetRename" then
		if self:rename(message.name, message.value) then self:closeDialog() end
	elseif kind == "deleteEqualizerPreset" then
		if self:delete(message.name) then self:closeDialog() end
	end
end

return Equalizer
