-- Updates: which build this copy is, what newer build its chosen line offers, and the one download
-- that replaces the executable. The rules about versions and asset names are here as plain
-- functions so a test can read them without a window or a network, and the platform's own
-- installer -- which knows where the executable is and how to replace it -- lives beside this in
-- `install.lua` and is only reached when there is something to install.
local json = require("json")
local jit = require("jit")
local wonderland = require("wonderland")
local platform = require("beat.platform")
local version = require("beat.version")

local time = wonderland.time

local RELEASES_URL = "https://api.github.com/repos/bycruz/beat/releases?per_page=20"
-- A launch checks once, a little after the window is up, rather than while the library is being
-- read and the first page is still being built.
local CHECK_DELAY = 8

---@class beat.UpdateAsset
---@field name string
---@field browser_download_url string

---@class beat.UpdateRelease
---@field tag_name string?
---@field prerelease boolean?
---@field draft boolean?
---@field body string?
---@field assets beat.UpdateAsset[]?

---@class beat.UpdateOffer
---@field tag string # The release's tag, as GitHub names it
---@field label string # What a dialog calls it
---@field url string # The download for this platform
---@field assetName string # The file name the URL ends with
---@field commit string? # The nightly's first seven characters, when there is one

---@class beat.UpdateVersion
---@field base string # Major.minor.patch, without the build's own suffix
---@field nightly boolean
---@field hash string?
---@field dev boolean
---@field platform { os: string?, arch: string?, android: boolean? }? # A test's stand-in for this machine

---@class beat.UpdateService: beat.Service
---@field app beat.App
---@field settings beat.SettingsService
---@field toasts beat.ToastsService
---@field http beat.HttpService
---@field system beat.SystemService
---@field emit fun(message: table)
---@field installedVersion string
---@field installed beat.UpdateVersion
---@field unsupported boolean # This build cannot replace itself: a source run or a dev build
---@field status "idle"|"checking"|"upToDate"|"available"|"downloading"|"ready"|"failed"|"unsupported"
---@field offer beat.UpdateOffer?
---@field error string?
---@field progress number?
---@field request beat.HttpHandle?
---@field dirty boolean # A status or progress change the next tick owes the screen
---@field offered boolean # An automatic check has already opened the dialog this launch
---@field checkedAutomatically boolean
---@field createdAt number
local Update = {}
Update.__index = Update
Update.needs = { "app", "settings", "toasts", "http", "system", "emit" }

--- Splits a version as the build wrote it: `0.1.0`, `0.1.0-nightly+1a2b3c4`, or `0.1.0-dev`.
--- A release tag's leading `v` is not part of the version.
---@param str string?
---@return beat.UpdateVersion
function Update.parseVersion(str)
	local value = tostring(str or ""):gsub("^v", "")
	local base, rest = value:match("^([%d%.]+)(.*)$")
	if base == nil then return { base = value, nightly = false, hash = nil, dev = false } end

	local hash = rest:match("^%-nightly%+(%x+)")
	return { base = base, nightly = hash ~= nil, hash = hash, dev = rest:match("^%-dev") ~= nil }
end

---@param value string
---@return number[]
local function versionParts(value)
	local parts = {}
	for piece in tostring(value or ""):gmatch("%d+") do parts[#parts + 1] = tonumber(piece) or 0 end
	return parts
end

--- Compares two `major.minor.patch` versions: -1 when `a` is older, 1 when it is newer.
---@param a string
---@param b string
---@return number
function Update.compareVersions(a, b)
	local left, right = versionParts(a), versionParts(b)
	for index = 1, math.max(#left, #right) do
		local x, y = left[index] or 0, right[index] or 0
		if x < y then return -1 end
		if x > y then return 1 end
	end
	return 0
end

--- The asset a platform installs from. A desktop build is a zip holding the one executable, or
--- the AppImage itself when that is what is running; a phone installs an APK, and the system's
--- installer decides when to replace the app.
---@param info { os: string?, arch: string?, android: boolean?, appImage: boolean? }
---@return string?
function Update.assetName(info)
	if info == nil then return nil end
	if info.android then
		if info.arch == "arm64" then return "beat-android-aarch64.apk" end
		if info.arch == "x64" then return "beat-android-x86-64.apk" end
		return nil
	end

	local arch = info.arch == "x64" and "x86-64" or (info.arch == "arm64" and "aarch64" or nil)
	if arch == nil then return nil end

	local osName = info.os
	if osName == "Linux" and info.appImage then return "beat-linux-" .. arch .. ".AppImage" end
	if osName == "Linux" then return "beat-linux-" .. arch .. ".zip" end
	if osName == "Windows" then return "beat-windows-" .. arch .. ".zip" end
	if osName == "OSX" then return "beat-macos-" .. arch .. ".zip" end
	return nil
end

--- The seven-character commit a nightly's notes name.
---@param body string?
---@return string?
local function commitOf(body)
	if type(body) ~= "string" then return nil end
	local sha = body:match("Commit:%s*`?(%x+)")
	return sha ~= nil and sha:sub(1, 7) or nil
end

---@param release beat.UpdateRelease
---@param info { os: string?, arch: string?, android: boolean? }
---@return beat.UpdateAsset?
local function assetOf(release, info)
	local wanted = Update.assetName(info)
	if wanted == nil then return nil end
	for _, asset in ipairs(release.assets or {}) do
		if asset.name == wanted then return asset end
	end
	return nil
end

--- The offer a channel has for the installed build, or nil when there is nothing newer or nothing
--- this platform can install. A nightly follows its commit, even between two builds that carry the
--- same version; a release follows the stable line's version, and an installed nightly is offered
--- the stable line's own build so switching lines is a click rather than a fresh download.
---@param releases beat.UpdateRelease[]?
---@param channel "release"|"nightly"|string
---@param installed beat.UpdateVersion|string
---@return beat.UpdateOffer?
function Update.pick(releases, channel, installed)
	if type(releases) ~= "table" then return nil end
	if type(installed) == "string" then installed = Update.parseVersion(installed) end
	if type(installed) ~= "table" then return nil end

	local info = installed.platform
		or { os = jit.os, arch = jit.arch, android = platform.android, appImage = (os.getenv("APPIMAGE") or "") ~= "" }

	if channel == "nightly" then
		---@type beat.UpdateRelease?
		local nightly
		for _, release in ipairs(releases) do
			if release.tag_name == "nightly" and release.draft ~= true then
				nightly = release
				break
			end
		end
		if nightly == nil then return nil end

		local commit = commitOf(nightly.body)
		if commit == nil then return nil end
		-- The same nightly is already installed, so there is nothing to offer.
		if installed.nightly and installed.hash == commit then return nil end

		local asset = assetOf(nightly, info)
		if asset == nil then return nil end
		return {
			tag = "nightly",
			label = "nightly " .. commit,
			url = asset.browser_download_url,
			assetName = asset.name,
			commit = commit
		}
	end

	---@type beat.UpdateRelease?
	local stable
	for _, release in ipairs(releases) do
		if release.draft ~= true and release.prerelease ~= true and release.tag_name ~= "nightly" then
			stable = release
			break
		end
	end
	if stable == nil then return nil end

	local tag = tostring(stable.tag_name or "")
	local parsed = Update.parseVersion(tag)
	if parsed.base == "" then return nil end

	local newer = Update.compareVersions(parsed.base, installed.base) > 0
	-- A nightly that is older than the stable line still switches to it: the two are different
	-- builds, and the stable one is the one the person asked to follow.
	if not newer and not installed.nightly then return nil end

	local asset = assetOf(stable, info)
	if asset == nil then return nil end
	return {
		tag = tag,
		label = "beat " .. parsed.base,
		url = asset.browser_download_url,
		assetName = asset.name
	}
end

--- The running executable's path, or nil for a source run. `known` says whether there was an
--- installer to ask: without `install.lua` -- a test, or a checkout before its first build -- the
--- answer is not a source run, it is no answer at all.
---@return string?, boolean
local function executablePath()
	local ok, install = pcall(require, "beat.app.services.update.install")
	if not ok or type(install) ~= "table" then return nil, false end
	local selfPath = install.selfPath --[[@as fun(): string?]]
	if type(selfPath) ~= "function" then return nil, false end
	local called, path = pcall(selfPath)
	if not called or type(path) ~= "string" then return nil, called end
	return path, true
end

---@param deps {
--- app: beat.App,
--- settings: beat.SettingsService,
--- toasts: beat.ToastsService,
--- http: beat.HttpService,
--- system: beat.SystemService,
--- emit: fun(message: table),
--- }
---@return beat.UpdateService
function Update.new(deps)
	local installedVersion = version
	local installed = Update.parseVersion(installedVersion)

	-- A dev build has no line to follow; a source run is not an executable that can be replaced;
	-- a Flatpak's executable is read-only and Flatpak itself updates it. All three still show the
	-- Update row, so a manual check can say why it has nothing to do.
	local unsupported = installed.dev or os.getenv("FLATPAK_ID") ~= nil
	if not unsupported and not platform.android then
		local path, known = executablePath()
		if known and path == nil then unsupported = true end
	end

	return setmetatable(
		{
			app = deps.app,
			settings = deps.settings,
			toasts = deps.toasts,
			http = deps.http,
			system = deps.system,
			emit = deps.emit,
			installedVersion = installedVersion,
			installed = installed,
			unsupported = unsupported,
			status = unsupported and "unsupported" or "idle",
			offer = nil,
			error = nil,
			progress = nil,
			request = nil,
			dirty = false,
			offered = false,
			checkedAutomatically = false,
			createdAt = time.now()
		},
		Update
	)
end

--- The line this launch follows: the chosen one, or the installed build's own when nothing was
--- chosen.
---@return "release"|"nightly"
function Update:channel()
	local chosen = self.settings.values.updateChannel
	if chosen == "release" then return "release" end
	if chosen == "nightly" then return "nightly" end
	return self.installed.nightly ? "nightly" : "release"
end

---@param manual boolean?
function Update:check(manual)
	if self.unsupported then
		self.status = "unsupported"
		self.dirty = true
		if manual then self.toasts:show("Updates are not available in this build", "info") end
		return
	end

	if self.request ~= nil then
		self.request:cancel()
		self.request = nil
	end

	self.status = "checking"
	self.offer = nil
	self.error = nil
	self.progress = nil
	self.dirty = true

	local wantedManual = manual == true
	self.request = self.http:request({
		url = RELEASES_URL,
		headers = {
			["Accept"] = "application/vnd.github+json",
			-- GitHub refuses a request without an agent. The http service sends a browser-like one;
			-- naming beat here is what the releases API asks of an app that reuses its answer.
			["User-Agent"] = "beat/" .. self.installedVersion
		},
		onDone = |response| -> self:checked(response, wantedManual)
	})
end

---@param response beat.HttpResponse
---@param manual boolean
function Update:checked(response, manual)
	self.request = nil

	---@type string?
	local err
	if response.error ~= nil then
		err = response.error
	elseif response.status < 200 or response.status >= 300 then
		err = "HTTP " .. tostring(response.status)
	elseif type(response.body) ~= "string" then
		err = "GitHub sent an empty answer"
	end

	local releases
	if err == nil then
		local ok, decoded = pcall(json.decode, response.body)
		if not ok or type(decoded) ~= "table" then
			err = "GitHub sent an answer beat could not read"
		else
			releases = decoded
		end
	end

	if err ~= nil then
		self.status = "failed"
		self.error = err
		self.dirty = true
		if manual then self.toasts:show("Could not check for updates: " .. err, "error") end
		return
	end

	local offer = Update.pick(releases, self:channel(), self.installed)
	self.offer = offer
	if offer == nil then
		self.status = "upToDate"
	else
		self.status = "available"
		-- An automatic check opens the dialog once a launch; a manual one leaves the person where
		-- they were, with the offer in the settings row they are already looking at.
		if not manual and not self.offered then
			self.offered = true
			self.emit({ type = "open", overlay = "update" })
		end
	end
	self.dirty = true
end

--- Installs the offer the check found. A phone hands the APK to its browser, because only the
--- system's installer may replace an app; a desktop replaces the executable in place and leaves
--- the restart to the dialog.
function Update:apply()
	local offer = self.offer
	if offer == nil then return end

	if platform.android then
		if self.system:open(offer.url) then
			self.status = "idle"
			self.offer = nil
		else
			self.status = "failed"
			self.error = "Could not open a browser to download the update"
			self.toasts:show(self.error, "error")
		end
		self.dirty = true
		return
	end

	local ok, install = pcall(require, "beat.app.services.update.install")
	if not ok or type(install) ~= "table" or type(install.apply) ~= "function" then
		self.status = "failed"
		self.error = "The update installer is not available"
		self.toasts:show(self.error, "error")
		self.dirty = true
		return
	end

	local called, path = pcall(install.selfPath)
	if not called or path == nil then
		self.status = "unsupported"
		self.error = "Updating needs the downloaded beat app, not a source run"
		self.dirty = true
		return
	end

	self.status = "downloading"
	self.progress = nil
	self.error = nil
	self.dirty = true

	local started, failure = pcall(
		install.apply,
		self.app,
		{ url = offer.url, name = offer.assetName },
		{
			onProgress = function(fraction)
				self.progress = fraction
				self.dirty = true
			end,
			onDone = function(success, message)
				if success then
					self.status = "ready"
					self.progress = nil
				else
					self.status = "failed"
					self.progress = nil
					self.error = message or "the download failed"
					self.toasts:show("Could not install the update: " .. (message or "the download failed"), "error")
				end
				self.dirty = true
			end
		}
	)
	if not started then
		self.status = "failed"
		self.progress = nil
		self.error = tostring(failure)
		self.toasts:show("Could not install the update: " .. tostring(failure), "error")
		self.dirty = true
	end
end

--- Starts the executable that was just installed and ends this one.
function Update:relaunch()
	local ok, install = pcall(require, "beat.app.services.update.install")
	if not ok or type(install) ~= "table" or type(install.relaunch) ~= "function" then
		self.status = "failed"
		self.error = "The update installer is not available"
		self.dirty = true
		return
	end

	local called, failure = pcall(install.relaunch, self.app)
	if not called then
		self.status = "failed"
		self.error = tostring(failure)
		self.dirty = true
	end
end

Update.on = {
	---@param self beat.UpdateService
	---@param _message beat.CheckForUpdatesMessage
	checkForUpdates = function(self, _message) self:check(true) end,

	---@param self beat.UpdateService
	---@param _message beat.ApplyUpdateMessage
	applyUpdate = function(self, _message) self:apply() end,

	---@param self beat.UpdateService
	---@param _message beat.RelaunchUpdateMessage
	relaunchUpdate = function(self, _message) self:relaunch() end,

	--- Switching lines is a check of the other one: the offer that appears is the other build, not
	--- the one that was already on screen.
	---@param self beat.UpdateService
	---@param message beat.UpdateChannelMessage
	updateChannel = function(self, message)
		if message.value ~= "release" and message.value ~= "nightly" then return end
		self.settings.values.updateChannel = message.value
		self.settings:changed()
		self:check(true)
	end,

	---@param self beat.UpdateService
	---@param message beat.CheckUpdatesMessage
	checkUpdates = function(self, message)
		self.settings.values.checkUpdates = message.value == true
		self.settings:changed()
	end
}

---@param now number
---@return boolean changed
---@return boolean busy
function Update:step(now)
	local changed = self.dirty
	self.dirty = false

	if not self.checkedAutomatically and now - self.createdAt >= CHECK_DELAY then
		self.checkedAutomatically = true
		if self.settings.values.checkUpdates ~= false and not self.unsupported then
			self:check(false)
			changed = true
		end
	end

	local busy = self.status == "checking" or self.status == "downloading"
	return changed, busy
end

--- The app is set up again: a check still out has nobody left to hear its answer.
function Update:close()
	if self.request ~= nil then
		self.request:cancel()
		self.request = nil
	end
end

return Update
