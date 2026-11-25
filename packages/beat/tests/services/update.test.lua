-- The update service's decisions, without a window, a network or an installer: how a version
-- string reads, how two versions order, which file a platform installs, and whether a release
-- list has anything newer than the build that is running.
local test = require("lde-test")
local json = require("json")
local jit = require("jit")
local platform = require("beat.platform")
local update = require("beat.app.services.update")

local NIGHTLY_SHA = "1a2b3c4d5e6f7890abcdef1234567890abcdef12"

local ASSET_NAMES = {
	"beat-linux-x86-64.zip",
	"beat-linux-aarch64.zip",
	"beat-windows-x86-64.zip",
	"beat-windows-aarch64.zip",
	"beat-macos-x86-64.zip",
	"beat-macos-aarch64.zip",
	"beat-android-aarch64.apk",
	"beat-android-x86-64.apk"
}

--- Every platform's file, so a test runs wherever it is checked out.
---@param prefix string
---@return table[]
local function assets(prefix)
	local list = {}
	for _, name in ipairs(ASSET_NAMES) do
		list[#list + 1] = { name = name, browser_download_url = prefix .. "/" .. name }
	end
	return list
end

---@param sha string
---@return table
local function nightly(sha)
	return {
		tag_name = "nightly",
		prerelease = true,
		draft = false,
		body = "Nightly build\n\nCommit: `" .. sha .. "`\n",
		assets = assets("https://example.test/nightly")
	}
end

---@param tag string
---@param prerelease boolean?
---@param draft boolean?
---@return table
local function release(tag, prerelease, draft)
	return {
		tag_name = tag,
		prerelease = prerelease == true,
		draft = draft == true,
		body = "",
		assets = assets("https://example.test/" .. tag)
	}
end

local function thisPlatform()
	return { os = jit.os, arch = jit.arch, android = platform.android }
end

test.it("reads every version a build writes", function()
	local stable = update.parseVersion("0.1.0")
	test.equal(stable.base, "0.1.0")
	test.falsy(stable.nightly)
	test.falsy(stable.dev)
	test.equal(stable.hash, nil)

	local nightlyVersion = update.parseVersion("0.1.0-nightly+1a2b3c4")
	test.equal(nightlyVersion.base, "0.1.0")
	test.truthy(nightlyVersion.nightly)
	test.equal(nightlyVersion.hash, "1a2b3c4")
	test.falsy(nightlyVersion.dev)

	local dev = update.parseVersion("0.1.0-dev")
	test.equal(dev.base, "0.1.0")
	test.falsy(dev.nightly)
	test.truthy(dev.dev)
end)

test.it("orders versions by their numbers, not their text", function()
	test.equal(update.compareVersions("0.1.0", "0.1.0"), 0)
	test.equal(update.compareVersions("0.2.0", "0.1.9"), 1)
	test.equal(update.compareVersions("0.1.0", "0.2.0"), -1)
	test.equal(update.compareVersions("0.10.0", "0.9.0"), 1)
	test.equal(update.compareVersions("v1.0.0", "1.0.0"), 0)
end)

test.it("names the file each platform installs", function()
	test.equal(update.assetName({ os = "Linux", arch = "x64" }), "beat-linux-x86-64.zip")
	test.equal(update.assetName({ os = "Linux", arch = "arm64", appImage = true }), "beat-linux-aarch64.AppImage")
	test.equal(update.assetName({ os = "Windows", arch = "arm64" }), "beat-windows-aarch64.zip")
	test.equal(update.assetName({ os = "OSX", arch = "arm64" }), "beat-macos-aarch64.zip")
	test.equal(update.assetName({ os = "Linux", arch = "arm64", android = true }), "beat-android-aarch64.apk")
	test.equal(update.assetName({ os = "Linux", arch = "x64", android = true }), "beat-android-x86-64.apk")
	test.equal(update.assetName({ os = "Linux", arch = "mips" }), nil)
end)

test.it("has nothing to offer when the nightly is the one installed", function()
	local installed = update.parseVersion("0.1.0-nightly+" .. NIGHTLY_SHA:sub(1, 7))
	test.equal(update.pick({ nightly(NIGHTLY_SHA) }, "nightly", installed), nil)
end)

test.it("offers a nightly whose commit differs", function()
	local installed = update.parseVersion("0.1.0-nightly+0000000")
	local offer = update.pick({ nightly(NIGHTLY_SHA) }, "nightly", installed)

	test.truthy(offer)
	---@cast offer beat.UpdateOffer
	test.equal(offer.tag, "nightly")
	test.equal(offer.label, "nightly " .. NIGHTLY_SHA:sub(1, 7))
	test.equal(offer.commit, NIGHTLY_SHA:sub(1, 7))
	test.truthy(offer.url:find(offer.assetName, 1, true) ~= nil)
end)

test.it("offers a newer release and skips drafts and prereleases", function()
	local installed = update.parseVersion("0.1.0")
	local releases = {
		release("v0.3.0", false, true),
		release("v0.2.0-beta", true),
		release("v0.2.0")
	}
	local offer = update.pick(releases, "release", installed)

	test.truthy(offer)
	---@cast offer beat.UpdateOffer
	test.equal(offer.tag, "v0.2.0")
	test.equal(offer.label, "beat 0.2.0")
	test.equal(offer.assetName, update.assetName(thisPlatform()))
end)

test.it("has nothing to offer when the release is the one installed", function()
	test.equal(update.pick({ release("v0.1.0") }, "release", update.parseVersion("0.1.0")), nil)
end)

test.it("offers the stable line to an installed nightly", function()
	local installed = update.parseVersion("0.1.0-nightly+" .. NIGHTLY_SHA:sub(1, 7))
	local offer = update.pick({ release("v0.1.0"), nightly(NIGHTLY_SHA) }, "release", installed)

	test.truthy(offer)
	---@cast offer beat.UpdateOffer
	test.equal(offer.tag, "v0.1.0")
	test.equal(offer.label, "beat 0.1.0")
end)

test.it("offers the nightly line to an installed release", function()
	local installed = update.parseVersion("0.1.0")
	local offer = update.pick({ nightly(NIGHTLY_SHA) }, "nightly", installed)

	test.truthy(offer)
	---@cast offer beat.UpdateOffer
	test.equal(offer.label, "nightly " .. NIGHTLY_SHA:sub(1, 7))
end)

test.it("leaves a platform with no asset unoffered", function()
	local installed = { base = "0.1.0", nightly = false, dev = false, platform = { os = "Plan9", arch = "x64" } }
	test.equal(update.pick({ release("v0.2.0") }, "release", installed), nil)
	test.equal(update.pick({ nightly(NIGHTLY_SHA) }, "nightly", installed), nil)
end)

--- A service with only what a check reads, and an http stand-in that answers GitHub's compare
--- endpoint with `comparison` ("ahead", "behind", "identical", or nil for a commit GitHub does
--- not know).
---@param installed string
---@param comparison string?
local function checking(installed, comparison)
	local asked = {} ---@type string[]
	local service = setmetatable({
		installed = update.parseVersion(installed),
		installedVersion = installed,
		settings = { values = { updateChannel = "nightly" } },
		toasts = { show = function() end },
		offered = true,
		dirty = false,
		http = {
			---@param request { url: string, onDone: fun(response: table) }
			request = function(_, request)
				asked[#asked + 1] = request.url
				if comparison == nil then
					request.onDone({ status = 404, body = json.encode({ message = "Not Found" }) })
				else
					request.onDone({ status = 200, body = json.encode({ status = comparison }) })
				end
				return { cancel = function() end }
			end
		}
	}, { __index = update })
	return service, asked
end

test.it("reads GitHub's answer as the JSON text it arrives as", function()
	-- The list reaches the service as a response body, not as tables: a check that read it
	-- through the decoder's document handle saw no releases at all and said every build was up to
	-- date. This goes through the same decode the service does.
	local service = checking("0.1.0-nightly+0000000", "ahead")
	service:checked({ status = 200, body = json.encode({ nightly(NIGHTLY_SHA) }) }, true)

	test.equal(service.error, nil)
	test.equal(service.status, "available")
	test.equal(service.offer and service.offer.commit, NIGHTLY_SHA:sub(1, 7))
end)

test.it("offers a nightly only when its commit comes after the installed one", function()
	local body = json.encode({ nightly(NIGHTLY_SHA) })

	local ahead, asked = checking("0.1.0-nightly+0000000", "ahead")
	ahead:checked({ status = 200, body = body }, true)
	test.equal(ahead.status, "available", "a later nightly is offered")
	test.truthy(asked[1]:find("0000000..." .. NIGHTLY_SHA:sub(1, 7), 1, true), "installed first, nightly second")

	local behind = checking("0.1.0-nightly+0000000", "behind")
	behind:checked({ status = 200, body = body }, true)
	test.equal(behind.status, "upToDate", "a build newer than the nightly is not offered the older one")
	test.equal(behind.offer, nil)

	local unknown = checking("0.1.0-nightly+0000000", nil)
	unknown:checked({ status = 200, body = body }, true)
	test.equal(unknown.status, "upToDate", "a commit GitHub has not seen is left alone")
end)
