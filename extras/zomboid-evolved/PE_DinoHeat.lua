-- Project Evolution safe zones + frontier density (server-side only, outside the Lua checksum).
-- 1) Shrinking safe zone: no dino of any kind spawns within safeRadius() of a spawn-zone center
--    (the mod's natural spawns, group partners, nests and bait all go through
--    DinoSpawnSafety.beginNaturalSpawnCheck, which is wrapped here; new migrations can't pick a
--    route that passes inside it). The radius shrinks from SAFE_START to SAFE_END over RAMP_DAYS
--    real days, so the areas around the zones get less safe as the server ages.
-- 2) Frontier density: outside the safe zone, keeps a target number of dinos around each outdoor
--    player, scaled by distance past the safe edge and by server age.
-- 3) Hard keep-out: any dino that ends up within CORE_RADIUS of a zone center (chasing a player in,
--    wandering, herding) is despawned, the same way the mod's migration code removes animals.
-- 4-6) Camp pressure (shelter budget, loot-free cores, post-collapse night raids): see that section.
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
local TIME_FLOOR = 0.5                -- time heat on day 0 (doubled 2026-09-27; was 0.25)
local MAX_LOCAL = 40                  -- target dinos near a player at full heat (distance 1 x time 1)
local COUNT_RADIUS = 90               -- tiles around a player counted toward the target
local SPAWN_MIN, SPAWN_MAX = 40, 75   -- spawn ring around the player (loaded chunks only)
local CHECK_SECONDS = 15              -- real seconds between checks per player
local GLOBAL_CAP = 400                -- hard ceiling on loaded dinos server-wide
local CORE_RADIUS = 75                -- hard keep-out (tiles from a zone center); covers the 40x40 safehouse + yard
local EVICT_SECONDS = 3               -- real seconds between keep-out sweeps

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

local originalSpawnCheck = nil          -- the mod's unwrapped check (set by wrapSpawnSafety)

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

-- ===== Camp pressure (sections 4-6) =====================================================
-- 4) Shelter budget: each player gets CAMP_BUDGET real seconds inside a camp core. Time outside
--    (online or offline) refills it at CAMP_REGEN per second. Past the budget the player is an
--    "overstayer": they're called out in chat, the keep-out stops shielding dinos sent after them,
--    and a small raptor pack is steered at them every HUNT_EVERY seconds while they stay in camp.
-- 5) Camp cores hold no loot: any container inside CAMP_RADIUS spawns empty.
-- 6) Night raids: once the safe radius has collapsed to SAFE_END, an occupied camp may be raided
--    at night (RAID_CHANCE per in-game night). The keep-out is lifted there for RAID_SECONDS.
-- Chat goes out as "[PE-Say]" console lines, relayed to in-game chat by pe-broadcast.service.
local CAMP_RADIUS = CORE_RADIUS
local CAMP_BUDGET = 2 * 3600          -- real seconds of shelter before overstaying
local CAMP_REGEN = 0.5                -- budget refilled per real second spent outside a camp
local CAMP_WARN_AT = 0.75             -- warn at this fraction of the budget
local OFFLINE_GAP = 60                -- a gap longer than this between updates counts as time away
local CAMP_TICK = 5                   -- real seconds between budget updates
local HUNT_EVERY = 240                -- real seconds between pack checks per overstayer
local HUNT_PACK = 2                   -- raptors kept near an overstayer
local HUNT_RADIUS = 60                -- tiles around the overstayer counted toward HUNT_PACK
local HUNT_SPAWN_MIN, HUNT_SPAWN_MAX = 40, 60
local HUNT_GIVE_UP = 600              -- real seconds a steered dino tries before being released
local RAID_CHANCE = 0.35              -- per in-game night, only once the zone has fully collapsed
local RAID_NIGHT_START, RAID_NIGHT_END = 22, 4
local RAID_PACK_MIN, RAID_PACK_MAX = 4, 6
local RAID_DELAY = 60                 -- real seconds from the warning to the pack
local RAID_SECONDS = 15 * 60          -- how long the keep-out is lifted at the raided camp
local CAMP_NAMES = { "Zone Alpha", "Zone Bravo", "Zone Charlie", "Zone Delta" }
local CAMP_KEY = "PECamp"

local function say(msg) print("[PE-Say] " .. msg) end

local function nearestZone(x, y)
    local bestI, best = 1, math.huge
    for i, z in ipairs(ZONES) do
        local dx, dy = x - z[1], y - z[2]
        local d = math.sqrt(dx * dx + dy * dy)
        if d < best then bestI, best = i, d end
    end
    return bestI, best
end

local function campData()
    local md = ModData.getOrCreate(CAMP_KEY)
    if type(md.players) ~= "table" then md.players = {} end
    return md
end

local function findOnline(name)
    local players = getOnlinePlayers()
    if not players then return nil end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and p:getUsername() == name then return p end
    end
    return nil
end

local function isOverstayer(name)
    local rec = campData().players[name]
    return rec ~= nil and (tonumber(rec.used) or 0) >= CAMP_BUDGET
end

-- Steered dinos (hunts and raids). exempt[animal] keeps the keep-out off them while steered.
local drivers = {}
local exempt = setmetatable({}, { __mode = "k" })
local raidUntil = {}                  -- zone index -> real second the raid ends

-- The keep-out holds for every dino but the steered ones (hunts and raids). A raid no longer lifts it
-- for the whole camp (the user's call, 2026-09-28): the raid is just the pack.
local function keepOutApplies(a, now)
    return not exempt[a]
end

local function animalOn(cell, typeName, sq)
    local animals = cell:getAnimals()
    for i = 0, animals:size() - 1 do
        local a = animals:get(i)
        if a and not exempt[a] and not a:isDead() and a:getAnimalType() == typeName
                and math.floor(a:getX()) == sq:getX() and math.floor(a:getY()) == sq:getY() then
            return a
        end
    end
    return nil
end

-- Spawns one steered dino in a ring around (cx, cy). No safe-zone or structure checks on purpose.
local function spawnSteered(label, cx, cy, rMin, rMax, groupId, entry)
    local cfg = DinoPopulation.speciesConfig(label)
    local cell = getCell()
    if not (cfg and cell) then return false end
    for _ = 1, 20 do
        local ang = ZombRandFloat(0, math.pi * 2)
        local dist = rMin + ZombRand(rMax - rMin + 1)
        local sq = cell:getGridSquare(math.floor(cx + math.cos(ang) * dist), math.floor(cy + math.sin(ang) * dist), 0)
        if sq and DinoPopulation.isUsableOutdoorSquare(sq) and DinoPopulation.spawnAnimal(sq, cfg, groupId) then
            local a = animalOn(cell, cfg.ns.TYPE, sq)
            if a then
                entry.animal = a
                exempt[a] = true
                drivers[#drivers + 1] = entry
                return true
            end
        end
    end
    return false
end

local function release(entry)
    local a = entry.animal
    if a then
        exempt[a] = nil
        pcall(function() a:setStateEventDelayTimer(0.0) end)
    end
end

-- Returns false when the entry is finished.
local function serviceDriver(entry, now, nowMs)
    local a = entry.animal
    if not a or a:isDead() then return false end
    local tx, ty
    if entry.kind == "hunt" then
        local p = findOnline(entry.target)
        -- an admin test hunt (entry.forced) keeps going even when the target isn't an overstayer
        if not p or p:isDead() or not (entry.forced or isOverstayer(entry.target)) then release(entry) return false end
        tx, ty = p:getX(), p:getY()
    else
        if now >= (raidUntil[entry.zone] or 0) then release(entry) return false end
        tx, ty = entry.x, entry.y
    end
    local state = VDinoState and VDinoState.get(a)
    if state and (state.attack or (state.movement and state.movement.pursuit)) then
        entry.engaged = true      -- the mod's AI has a target; stop steering, stay exempt
        return true
    end
    if not entry.engaged and now - entry.started > HUNT_GIVE_UP then release(entry) return false end
    pcall(function() a:setStateEventDelayTimer(1000000.0) end)
    if nowMs >= (entry.nextPath or 0) then
        VDinoMovement.pathToLocation(a, tx, ty, 0, { running = true })
        entry.nextPath = nowMs + 2000
    end
    if VDinoState and VDinoState.setTask then VDinoState.setTask(a, "bait_approach", nowMs, nil) end
    return true
end

local function driversTick(now)
    if #drivers == 0 then return end
    local nowMs = getTimestampMs()
    for i = #drivers, 1, -1 do
        local ok, keep = pcall(serviceDriver, drivers[i], now, nowMs)
        if not ok or not keep then table.remove(drivers, i) end
    end
end

local function dinosNear(x, y, r)
    local cell = getCell()
    local animals = cell and cell:getAnimals()
    if not animals then return 0 end
    local n, r2 = 0, r * r
    for i = 0, animals:size() - 1 do
        local a = animals:get(i)
        if isDino(a) and (a:getX() - x) ^ 2 + (a:getY() - y) ^ 2 <= r2 then n = n + 1 end
    end
    return n
end

local function sendHunters(p, name, now, forced)
    local need = HUNT_PACK - dinosNear(p:getX(), p:getY(), HUNT_RADIUS)
    if need <= 0 then return end
    local groupId = VDinoHerd and VDinoHerd.newGroupId and VDinoHerd.newGroupId() or nil
    local made = 0
    for _ = 1, need do
        if spawnSteered("raptor", p:getX(), p:getY(), HUNT_SPAWN_MIN, HUNT_SPAWN_MAX, groupId,
                { kind = "hunt", target = name, started = now, forced = forced }) then made = made + 1 end
    end
    log(string.format("camp: sent %d raptor(s) after overstayer %s", made, name))
end

local lastCamp = 0
local function campTick(now)
    if now - lastCamp < CAMP_TICK then return end
    lastCamp = now
    local players = getOnlinePlayers()
    if not players then return end
    local md = campData()
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        local name = p and p:getUsername()
        if name and not p:isDead() then
            local rec = md.players[name]
            if type(rec) ~= "table" then rec = { used = 0, last = now } md.players[name] = rec end
            local elapsed = now - (tonumber(rec.last) or now)
            rec.last = now
            if elapsed > OFFLINE_GAP then        -- they were away: refill for that gap
                rec.used = math.max(0, (tonumber(rec.used) or 0) - elapsed * CAMP_REGEN)
                elapsed = 0
            end
            local idx, d = nearestZone(p:getX(), p:getY())
            local inCamp = d < CAMP_RADIUS
            local used = tonumber(rec.used) or 0
            if inCamp then used = math.min(CAMP_BUDGET * 1.5, used + elapsed)
            else used = math.max(0, used - elapsed * CAMP_REGEN) end
            rec.used = used
            if inCamp and used >= CAMP_BUDGET * CAMP_WARN_AT and not rec.warned then
                rec.warned = true
                say(string.format("%s: the dinosaurs are catching your scent at %s. About %d min of shelter left - get out and roam.",
                    name, CAMP_NAMES[idx], math.max(1, math.floor((CAMP_BUDGET - used) / 60))))
            end
            if inCamp and used >= CAMP_BUDGET then
                if not rec.overstayed then
                    rec.overstayed = true
                    say(string.format("%s has worn out their welcome at %s. The raptors are coming.", name, CAMP_NAMES[idx]))
                end
                if now - (tonumber(rec.lastHunt) or 0) >= HUNT_EVERY then
                    rec.lastHunt = now
                    sendHunters(p, name, now)
                end
            end
            if used < CAMP_BUDGET * 0.5 then rec.warned, rec.overstayed = nil, nil end
        end
    end
end

-- Night raids -----------------------------------------------------------------------------------
local pendingRaid = nil               -- { zone, at, player }

local function occupiedCamps()
    local out = {}
    local players = getOnlinePlayers()
    if not players then return out end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and not p:isDead() then
            local idx, d = nearestZone(p:getX(), p:getY())
            if d < CAMP_RADIUS + 25 then out[#out + 1] = { zone = idx, player = p:getUsername() } end
        end
    end
    return out
end

local function raidHour()
    if safeRadius() > SAFE_END + 0.5 or pendingRaid then return end
    local gt = getGameTime()
    local hour = gt:getHour()
    if not (hour >= RAID_NIGHT_START or hour < RAID_NIGHT_END) then return end
    local night = math.floor((gt:getWorldAgeHours() + (24 - RAID_NIGHT_START)) / 24)
    local md = campData()
    if md.rolledNight == night then return end
    local camps = occupiedCamps()
    if #camps == 0 then return end        -- try again next hour tonight
    md.rolledNight = night
    if ZombRandFloat(0, 1) > RAID_CHANCE then return end
    local pick = camps[ZombRand(#camps) + 1]
    pendingRaid = { zone = pick.zone, at = nowSeconds() + RAID_DELAY, player = pick.player }
    say(string.format("The herd is restless tonight. Something is circling %s...", CAMP_NAMES[pick.zone]))
    log("raid armed on " .. CAMP_NAMES[pick.zone])
end

local function raidTick(now)
    if pendingRaid and now >= pendingRaid.at then
        local r = pendingRaid
        pendingRaid = nil
        local anchor = findOnline(r.player)
        if not anchor then
            local camps = occupiedCamps()
            for _, c in ipairs(camps) do if c.zone == r.zone then anchor = findOnline(c.player) break end end
        end
        if not anchor then log("raid on " .. CAMP_NAMES[r.zone] .. " called off: camp empty") return end
        raidUntil[r.zone] = now + RAID_SECONDS
        local z = ZONES[r.zone]
        local groupId = VDinoHerd and VDinoHerd.newGroupId and VDinoHerd.newGroupId() or nil
        local made = 0
        for _ = 1, RAID_PACK_MIN + ZombRand(RAID_PACK_MAX - RAID_PACK_MIN + 1) do
            if spawnSteered("raptor", anchor:getX(), anchor:getY(), HUNT_SPAWN_MIN, HUNT_SPAWN_MAX, groupId,
                    { kind = "raid", zone = r.zone, x = z[1], y = z[2], started = now }) then made = made + 1 end
        end
        say(string.format("RAID! Raptors are breaking into %s!", CAMP_NAMES[r.zone]))
        log(string.format("raid on %s: %d raptors, steered in for %ds", CAMP_NAMES[r.zone], made, RAID_SECONDS))
    end
    for idx, untilAt in pairs(raidUntil) do
        if now >= untilAt then
            raidUntil[idx] = nil
            say(string.format("The herd pulls back from %s.", CAMP_NAMES[idx]))
        end
    end
end

-- Loot-free camp cores (section 5).
Events.OnFillContainer.Add(function(roomName, containerType, container)
    if not container then return end
    local sq = container:getSourceGrid()
    if not sq then return end
    local _, d = nearestZone(sq:getX(), sq:getY())
    if d < CAMP_RADIUS then container:removeAllItems() end
end)

-- Despawn every dino inside a zone core. Returns how many were removed.
local function evictCore(animals)
    local now = nowSeconds()
    local removed = {}
    for i = 0, animals:size() - 1 do
        local a = animals:get(i)
        if isDino(a) and zoneDistance(a:getX(), a:getY()) < CORE_RADIUS and keepOutApplies(a, now) then removed[#removed + 1] = a end
    end
    for i = #removed, 1, -1 do
        -- PE_Sentries shoots wanderers (a real corpse) and keeps them while it does; it hands one
        -- back for the old silent despawn if it hasn't fired in time.
        if PESentries and PESentries.claim then
            local ok, owned = pcall(PESentries.claim, removed[i])
            if ok and owned then table.remove(removed, i) end
        end
    end
    for _, a in ipairs(removed) do
        local okT, kind = pcall(function() return a:getAnimalType() end)
        log(string.format("keep-out: removed %s at %d,%d", okT and tostring(kind) or "dino", math.floor(a:getX()), math.floor(a:getY())))
        if VDinoState and VDinoState.clear then pcall(VDinoState.clear, a) end
        pcall(function() a:removeFromWorld() end)
        pcall(function() a:removeFromSquare() end)
    end
    return #removed
end
-- Admin test triggers (PE_AdminCmd's cmd.txt). They skip the timers and the night/collapse/chance
-- gates, but the pack itself is the real one (sendHunters / the raid tick), so the sentries' pressure
-- pool meets exactly what players will.
--   <seq> hunt <username>            steer a hunt pack at the player now
--   <seq> raid <username> [delay]    arm a raid on the player's nearest camp (delay seconds, default 10)
if PEAdminCommands then
    local function adminLog(msg) print("[PE-Admin] " .. msg) end
    PEAdminCommands.hunt = function(args)
        local p = findOnline(args[1] or "")
        if not p then return adminLog("player not online: " .. tostring(args[1])) end
        local near = dinosNear(p:getX(), p:getY(), HUNT_RADIUS)
        if near >= HUNT_PACK then adminLog(string.format("hunt: %d dino(s) already within %d tiles, so none sent", near, HUNT_RADIUS)) end
        sendHunters(p, p:getUsername(), nowSeconds(), true)
    end
    PEAdminCommands.raid = function(args)
        local p = findOnline(args[1] or "")
        if not p then return adminLog("player not online: " .. tostring(args[1])) end
        if pendingRaid then return adminLog("raid already armed on " .. CAMP_NAMES[pendingRaid.zone]) end
        local idx, d = nearestZone(p:getX(), p:getY())
        local delay = math.max(tonumber(args[2]) or 10, 0)
        pendingRaid = { zone = idx, at = nowSeconds() + delay, player = p:getUsername() }
        say(string.format("The herd is restless tonight. Something is circling %s...", CAMP_NAMES[idx]))
        adminLog(string.format("raid armed on %s (%s is %.0f tiles from it), pack in %ds", CAMP_NAMES[idx], p:getUsername(), d, delay))
    end
end

PEDinoHeat = { safeRadius = safeRadius, inSafeZone = inSafeZone, zoneDistance = zoneDistance, evictCore = evictCore,
               CORE_RADIUS = CORE_RADIUS, nearestZone = nearestZone, campData = campData, say = say,
               CAMP_BUDGET = CAMP_BUDGET, sendHunters = sendHunters, raidUntil = raidUntil, drivers = drivers,
               ZONES = ZONES, CAMP_NAMES = CAMP_NAMES, keepOutApplies = keepOutApplies,
               serverDays = serverDays, SAFE_START = SAFE_START, SAFE_END = SAFE_END, RAMP_DAYS = RAMP_DAYS }

local lastEvict = 0
local function evictTick()
    local now = nowSeconds()
    if now - lastEvict < EVICT_SECONDS then return end
    lastEvict = now
    local cell = getCell()
    local animals = cell and cell:getAnimals()
    if animals and animals:size() > 0 then evictCore(animals) end
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
    local okC, errC = pcall(function()
        local now = nowSeconds()
        campTick(now)
        driversTick(now)
        raidTick(now)
    end)
    if not okC and nowSeconds() - lastError >= 60 then
        lastError = nowSeconds()
        log("camp error: " .. tostring(errC))
    end
    local okE, errE = pcall(evictTick)
    if not okE and nowSeconds() - lastError >= 60 then
        lastError = nowSeconds()
        log("keep-out error: " .. tostring(errE))
    end
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
    local okR, errR = pcall(raidHour)
    if not okR then log("raid error: " .. tostring(errR)) end
    local ok, err = pcall(filterMigrationRoutes)
    if not ok then log("route filter error: " .. tostring(err)) end
end)
