-- What beat's core is: the library, the scan that fills it, the queue, the player, artwork, and
-- the few settings a launch remembers. None of it knows what a screen looks like.
local Library = require("beat-core.library")
local Scanner = require("beat-core.scan")
local Queue = require("beat-core.queue")
local Player = require("beat-core.player")
local Spectrum = require("beat-core.spectrum")
local art = require("beat-core.art")
local settings = require("beat-core.settings")
local util = require("beat-core.util")
local Scrobbler = require("beat-core.scrobbler")
local Lastfm = require("beat-core.lastfm")
local cover_cache = require("beat-core.cover_cache")
local Taxonomy = require("beat-core.taxonomy")
local equalizer = require("beat-core.equalizer")

---@class beat.core
local core = {
Library = Library,
Scanner = Scanner,
Queue = Queue,
Player = Player,
Spectrum = Spectrum,
art = art,
settings = settings,
util = util,
Scrobbler = Scrobbler,
Lastfm = Lastfm,
cover_cache = cover_cache,
Taxonomy = Taxonomy,
equalizer = equalizer,
}

return core
