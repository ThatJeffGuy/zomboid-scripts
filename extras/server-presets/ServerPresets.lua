-- Server presets for Irish's Dinosaurs (VRaptor) + admin safezones. Server-side only: install it
-- in the game's media/lua/server/ (clients never load that folder, so it is outside the Lua
-- checksum). Applies once per world, tracked in global ModData, so a wiped world gets the
-- presets again and later in-game admin tweaks are not overwritten.
-- Bump PRESET_VERSION to force a re-apply.
if isClient() then return end

local PRESET_VERSION = 1
local STATE_KEY = "ServerPresets"
local DINO_KEY = "VDinoServerSettingsV1"

-- Irish's Dinosaurs (VRaptor) settings, raw values as VDinoSettings.apply() expects them.
local DINO = {
    raptorSpawn = 12.0,
    pachySpawn = 1.5,
    carnoSpawn = 1.0,
    stegoSpawn = 1.0,
    ankySpawn = 1.0,
    trexSpawn = 0.2,
    spawnPressure = 3.0,
    raptorGroup = 5,
    rerollMissedSpawns24h = true,
    structureRadius = 0,
}

local ZONE_OWNER = "admin"
local ZONE_HALF = 20
local ZONES = {
    { "Zone Alpha - West", 2122, 6569 },
    { "Zone Bravo - Southwest", 2892, 14941 },
    { "Zone Charlie - Southeast", 10353, 12532 },
    { "Zone Delta - Northeast", 12865, 4740 },
}

local function log(msg) print("[Server-Presets] " .. msg) end

local function applyDino()
    local state = ModData.getOrCreate(STATE_KEY)
    if (tonumber(state.dinoVersion) or 0) >= PRESET_VERSION then
        log("dino presets v" .. tostring(state.dinoVersion) .. " already applied; leaving in-game values alone")
        return
    end
    local data = ModData.getOrCreate(DINO_KEY)
    for k, v in pairs(DINO) do data[k] = v end
    data.initialized = true
    data.spawnDefaultsVersion = 4
    data.structureRadiusDefaultsVersion = 1
    if VDinoSettings and VDinoSettings.apply then
        VDinoSettings.apply(data)
        if VDinoServerSettings and VDinoServerSettings.persistCurrent then VDinoServerSettings.persistCurrent() end
    end
    state.dinoVersion = PRESET_VERSION
    log("dino presets v" .. PRESET_VERSION .. " applied")
end

local function reportDino()
    if not (VDinoSettings and VDinoSettings.snapshot) then log("VDinoSettings not loaded - is VRaptor enabled?"); return end
    local s = VDinoSettings.snapshot()
    log(string.format("dino live: raptor=%s pachy=%s carno=%s stego=%s anky=%s trex=%s pressure=%s raptorGroup=%s reroll24h=%s structureRadius=%s",
        tostring(s.raptorSpawn), tostring(s.pachySpawn), tostring(s.carnoSpawn), tostring(s.stegoSpawn),
        tostring(s.ankySpawn), tostring(s.trexSpawn), tostring(s.spawnPressure), tostring(s.raptorGroup),
        tostring(s.rerollMissedSpawns24h), tostring(s.structureRadius)))
end

local function applyZones()
    local state = ModData.getOrCreate(STATE_KEY)
    if (tonumber(state.zonesVersion) or 0) >= PRESET_VERSION then
        log("safezones v" .. tostring(state.zonesVersion) .. " already applied")
        return
    end
    local made, failed = 0, 0
    for _, z in ipairs(ZONES) do
        local title, cx, cy = z[1], z[2], z[3]
        local x, y, w = cx - ZONE_HALF, cy - ZONE_HALF, ZONE_HALF * 2
        local ok, existing = pcall(function() return SafeHouse.getSafeHouse(x, y, w, w) end)
        if ok and existing then
            log("safezone exists: " .. title)
        else
            local ok2, sh = pcall(function() return SafeHouse.addSafeHouse(x, y, w, w, ZONE_OWNER) end)
            if ok2 and sh then
                pcall(function() sh:setTitle(title) end)
                made = made + 1
                log(string.format("safezone created: %s at %d,%d %dx%d owner=%s", title, x, y, w, w, ZONE_OWNER))
            else
                failed = failed + 1
                log("FAILED to create safezone " .. title .. ": " .. tostring(sh))
            end
        end
    end
    if failed == 0 then state.zonesVersion = PRESET_VERSION else log(failed .. " safezone(s) failed; will retry next boot") end
    log("safezones done, created " .. made .. ", total safehouses now " .. tostring(SafeHouse.getSafehouseList():size()))
end

Events.OnInitGlobalModData.Add(applyDino)
Events.OnServerStarted.Add(function()
    local ok, err = pcall(applyZones)
    if not ok then log("safezone error: " .. tostring(err)) end
    reportDino()
end)
