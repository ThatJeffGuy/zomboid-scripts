-- Project Evolution safe zones + frontier density (server-side only, outside the Lua checksum).
-- 1) Shrinking safe zone: no dino of any kind spawns within safeRadius() of a spawn-zone center
--    (the mod's natural spawns, group partners, nests and bait all go through
--    DinoSpawnSafety.beginNaturalSpawnCheck, which is wrapped here; new migrations can't pick a
--    route that passes inside it). The radius shrinks from SAFE_START to SAFE_END over RAMP_DAYS
--    real days, so the areas around the zones get less safe as the server ages.
-- 2) Frontier density: outside the safe zone, keeps a target number of dinos around each outdoor
--    player, scaled by distance past the safe edge and by server age.
-- Tunables are all in this block. Edit the canonical copy in config/presets/.
if isClient() then return end

local ZONES = {                       -- same centers as PE_ServerPresets.lua safezones
    { 2122, 6569 }, { 2892, 14941 }, { 10353, 12532 }, { 12865, 4740 },
}
local SAFE_START = 1000               -- safe radius (tiles) on day 0
local SAFE_END = 150                  -- safe radius once the server is RAMP_DAYS old
local ROUTE_MARGIN = 100              -- extra clearance for migration routes past the safe edge
local HOT_RADIUS = 3000               -- tiles where distance heat reaches 1.0
local RAMP_DAYS = 30                  -- real days from first boot to full time heat
local TIME_FLOOR = 0.25               -- time heat on day 0 (so the frontier isn't empty at launch)
local MAX_LOCAL = 40                  -- target dinos near a player at full heat (distance 1 x time 1)
local COUNT_RADIUS = 90               -- tiles around a player counted toward the target
local SPAWN_MIN, SPAWN_MAX = 40, 75   -- spawn ring around the player (loaded chunks only)
local CHECK_SECONDS = 15              -- real seconds between checks per player
local GLOBAL_CAP = 400                -- hard ceiling on loaded dinos server-wide

local STATE_KEY = "PEDinoHeat"

local function log(msg) print("[PE-Heat] " .. msg) end

local function clamp01(v) if v < 0 then return 0 elseif v > 1 then return 1 end return v end

local function nowSeconds()
    return math.floor((getTimestampMs and getTimestampMs() or 0) / 1000)
end

local function serverDays()
    local state = ModData.getOrCreate(STATE_KEY)
    local now = nowSeconds()
    if not tonumber(state.startedAt) or tonumber(state.startedAt) <= 0 then
        state.startedAt = now
        log("server-age clock started")
    end
    return (now - tonumber(state.startedAt)) / 86400
end

local function timeHeat()
    local days = serverDays()
    return TIME_FLOOR + (1 - TIME_FLOOR) * clamp01(days / RAMP_DAYS), days
end

local function safeRadius()
    return SAFE_START + (SAFE_END - SAFE_START) * clamp01(serverDays() / RAMP_DAYS)
end

local function zoneDistance(x, y)
    local best = math.huge
    for _, z in ipairs(ZONES) do
        local dx, dy = x - z[1], y - z[2]
        local d = math.sqrt(dx * dx + dy * dy)
        if d < best then best = d end
    end
    return best
end

local function distanceHeat(x, y)
    local safe = safeRadius()
    return clamp01((zoneDistance(x, y) - safe) / (HOT_RADIUS - safe))
end

local function inSafeZone(x, y)
    return zoneDistance(x, y) < safeRadius()
end

-- Block every natural/nest/bait spawn inside the safe zone.
local function wrapSpawnSafety()
    if not (DinoSpawnSafety and DinoSpawnSafety.beginNaturalSpawnCheck) then
        log("DinoSpawnSafety not loaded - safe zones NOT enforced")
        return
    end
    if DinoSpawnSafety.PEWrapped then return end
    local original = DinoSpawnSafety.beginNaturalSpawnCheck
    originalSpawnCheck = original
    DinoSpawnSafety.beginNaturalSpawnCheck = function(square)
        if square and inSafeZone(square:getX(), square:getY()) then return { done = true, allowed = false } end
        return original(square)
    end
    DinoSpawnSafety.PEWrapped = true
    log("safe-zone spawn block active")
end

-- Distance from point to segment.
local function segmentDistance(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    local t = len2 > 0 and clamp01(((px - ax) * dx + (py - ay) * dy) / len2) or 0
    local cx, cy = ax + t * dx, ay + t * dy
    return math.sqrt((px - cx) ^ 2 + (py - cy) ^ 2)
end

local function routeClearance(route)
    local best = math.huge
    local pts = route and route.points or {}
    for i = 1, #pts - 1 do
        for _, z in ipairs(ZONES) do
            local d = segmentDistance(z[1], z[2], pts[i].x, pts[i].y, pts[i + 1].x, pts[i + 1].y)
            if d < best then best = d end
        end
    end
    return best
end

-- New migrations may only use routes that stay clear of the safe zone. Filters each definition's
-- routeIds (used only when a new migration picks a route), so herds already travelling are untouched.
local function filterMigrationRoutes()
    if not (VDinoMigration and VDinoMigration.DEFINITIONS and VDinoMigration.ROUTES) then return end
    local limit = safeRadius() + ROUTE_MARGIN
    local blocked = {}
    for _, def in pairs(VDinoMigration.DEFINITIONS) do
        if type(def) == "table" and type(def.routeIds) == "table" then
            def.PEAllRouteIds = def.PEAllRouteIds or def.routeIds
            local keep = {}
            for _, id in ipairs(def.PEAllRouteIds) do
                if routeClearance(VDinoMigration.ROUTES[id]) >= limit then keep[#keep + 1] = id
                else blocked[id] = true end
            end
            def.routeIds = keep
        end
    end
    local names = {}
    for id in pairs(blocked) do names[#names + 1] = id end
    table.sort(names)
    log(string.format("safe radius %.0f tiles; migration routes blocked: %s", safeRadius(),
        #names > 0 and table.concat(names, ", ") or "none"))
end

-- Species weights shift from grazers + raptors in warm areas to predators in hot ones.
local function pickSpecies(heat)
    local w = {
        { "raptor", 10 },
        { "pachy",  4 - 2 * heat },
        { "stego",  3 - 1.5 * heat },
        { "anky",   3 - 1.5 * heat },
        { "carno",  0.5 + 3 * heat },
        { "trex",   0.1 + 1.9 * heat },
    }
    local total = 0
    for _, e in ipairs(w) do total = total + e[2] end
    local pick = ZombRandFloat(0, total)
    for _, e in ipairs(w) do
        pick = pick - e[2]
        if pick <= 0 then return e[1] end
    end
    return "raptor"
end

-- Group bounds come from the mod's live per-species settings (PE_ServerPresets.lua *Group values);
-- heat decides how close to the max a group gets.
local function groupSize(cfg, heat)
    local lo, hi = 1, 1
    if VDinoDifficulty and not VDinoDifficulty.isSolitary(cfg.ns.TYPE) then
        lo, hi = VDinoDifficulty.groupSize(cfg.ns)
    end
    if hi <= lo then return hi end
    local top = lo + math.floor((hi - lo) * (0.4 + 0.6 * heat) + 0.5)
    return lo + ZombRand(top - lo + 1)
end

local function isDino(animal)
    return animal and not animal:isDead() and VDinoSpecies and VDinoSpecies.isDinosaur(animal)
end

local function nearbyCount(animals, x, y)
    local n, r2 = 0, COUNT_RADIUS * COUNT_RADIUS
    for i = 0, animals:size() - 1 do
        local a = animals:get(i)
        if isDino(a) then
            local dx, dy = a:getX() - x, a:getY() - y
            if dx * dx + dy * dy <= r2 then n = n + 1 end
        end
    end
    return n
end

local function totalCount(animals)
    local n = 0
    for i = 0, animals:size() - 1 do
        if isDino(animals:get(i)) then n = n + 1 end
    end
    return n
end

local function farFromPlayers(square, players)
    local min2 = SPAWN_MIN * SPAWN_MIN * 0.5
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and not p:isDead() then
            local dx, dy = square:getX() - p:getX(), square:getY() - p:getY()
            if dx * dx + dy * dy < min2 then return false end
        end
    end
    return true
end


-- Same rule as the mod's natural spawns: nothing within structureRadius of player builds or safehouses.
-- Uses the mod's original check, not the safe-zone wrapper (inSafeZone is tested separately).
local originalSpawnCheck = nil
local function nearPlayerBase(square)
    local check = originalSpawnCheck or (DinoSpawnSafety and DinoSpawnSafety.beginNaturalSpawnCheck)
    if not check then return false end
    local job = check(square)
    while not job.done do DinoSpawnSafety.stepNaturalSpawnCheck(job, 8192) end
    return not job.allowed
end

local function findSquare(cell, cx, cy, rMin, rMax, players, tries)
    for _ = 1, tries do
        local ang = ZombRandFloat(0, math.pi * 2)
        local dist = rMin + ZombRand(rMax - rMin + 1)
        local x = math.floor(cx + math.cos(ang) * dist)
        local y = math.floor(cy + math.sin(ang) * dist)
        local sq = cell:getGridSquare(x, y, 0)
        if sq and DinoPopulation.isUsableOutdoorSquare(sq) and farFromPlayers(sq, players) and not inSafeZone(x, y)
                and not nearPlayerBase(sq) then
            return sq
        end
    end
    return nil
end

local function spawnGroup(cell, player, players, label, heat)
    local cfg = DinoPopulation.speciesConfig(label)
    if not cfg then return 0 end
    local lead = findSquare(cell, player:getX(), player:getY(), SPAWN_MIN, SPAWN_MAX, players, 24)
    if not lead then return 0 end
    local size = groupSize(cfg, heat)
    local groupId = nil
    if size > 1 and VDinoHerd and VDinoHerd.newGroupId then groupId = VDinoHerd.newGroupId() end
    local made = DinoPopulation.spawnAnimal(lead, cfg, groupId) and 1 or 0
    if made == 0 then return 0 end
    for _ = 2, size do
        local sq = findSquare(cell, lead:getX(), lead:getY(), 2, 12, players, 10)
        if sq and DinoPopulation.spawnAnimal(sq, cfg, groupId) then made = made + 1 end
    end
    return made
end

local lastCheck = 0
local lastReport = 0

local function tick()
    if not (DinoPopulation and DinoPopulation.spawnAnimal and DinoPopulation.speciesConfig) then return end
    local now = nowSeconds()
    if now - lastCheck < CHECK_SECONDS then return end
    lastCheck = now

    local players = getOnlinePlayers()
    if not players or players:size() == 0 then return end
    local cell = getCell()
    if not cell then return end
    local animals = cell:getAnimals()
    if not animals then return end

    local tHeat, days = timeHeat()
    local total = totalCount(animals)
    local spawned = 0

    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and not p:isDead() and p:getZ() == 0 and not p:isInARoom() and total < GLOBAL_CAP then
            local dHeat = distanceHeat(p:getX(), p:getY())
            local heat = dHeat * tHeat
            local target = math.floor(MAX_LOCAL * heat + 0.5)
            if target > 0 and nearbyCount(animals, p:getX(), p:getY()) < target then
                local n = spawnGroup(cell, p, players, pickSpecies(heat), heat)
                spawned = spawned + n
                total = total + n
            end
        end
    end

    if now - lastReport >= 1800 or spawned > 0 and now - lastReport >= 300 then
        lastReport = now
        log(string.format("day %.1f safeRadius=%.0f timeHeat=%.2f loadedDinos=%d spawnedThisTick=%d", days, safeRadius(), tHeat, total, spawned))
    end
end

local lastError = 0
Events.OnTick.Add(function()
    local ok, err = pcall(tick)
    if not ok and nowSeconds() - lastError >= 60 then
        lastError = nowSeconds()
        log("error: " .. tostring(err))
    end
end)

Events.OnServerStarted.Add(function()
    local ok, err = pcall(function()
        serverDays()
        wrapSpawnSafety()
        filterMigrationRoutes()
    end)
    if not ok then log("startup error: " .. tostring(err)) end
end)

-- The safe radius shrinks continuously; re-check which migration routes are allowed every game hour.
Events.EveryHours.Add(function()
    local ok, err = pcall(filterMigrationRoutes)
    if not ok then log("route filter error: " .. tostring(err)) end
end)
