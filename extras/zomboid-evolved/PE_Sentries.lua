-- PE_Sentries.lua  (server-side only)
-- Camp defenses for Zomboid Evolved (the user's design, 2026-09-28). Every camp core (CORE tiles
-- around a zone center, the same area as the PE_DinoHeat keep-out) is guarded by sentry posts that
-- kill intruders:
--   * Wandering dinos: the keep-out used to despawn them silently. PE_DinoHeat's evictCore now hands
--     them to claim() here and the sentries shoot them instead (a real corpse via the mod's own
--     VDinoDeath.finalize). If the sentries haven't fired within CLAIM_FALLBACK, evictCore despawns
--     it the old way, so the camp is never left open by a problem in this script.
--   * Hostile bandits (brain.hostile/hostileP; friendly clans are left alone): a server-side kill
--     never sticks on a client-simulated bandit (live test 2026-09-28), so a shot bandit is deleted
--     through pe-broadcast.sh ("[PE-Zed] x y z 1" -> RCON removezombies): no corpse, no loot.
--   * Camp-pressure dinos (hunts on overstayers, night raids): these are the point of camp pressure,
--     so the sentries fight them with a small per-camp ammo pool (PRESSURE_CHARGES, recharging every
--     PRESSURE_RECHARGE). A hunt gets thinned out; a raid pack breaks through ("collapsing but still
--     defending").
-- Each camp also gets four log guard towers on its diagonals (see "Guard towers"), built with
-- transmitted objects the first time a player is near and the footprint is loaded and clear. Kills are announced per camp every ANNOUNCE_SECONDS via [PE-Say].
if isClient() then return end

local CORE = 75
local TICK_SECONDS = 1
local REACT_SECONDS = 2               -- wanderers: seconds inside the core before the posts fire
local SHOT_GAP_SECONDS = 1.5          -- per camp: at most one wanderer kill this often
local CLAIM_FALLBACK = 20             -- evictCore despawns a claimed dino still alive after this
local PRESSURE_CHARGES = 1            -- hunt/raid dinos: kills in hand per camp
local PRESSURE_RECHARGE = 7           -- seconds to regain one charge (the user's call, 2026-09-28; was 120)
local PRESSURE_REACT = 6              -- hunt/raid dinos: seconds inside before the posts fire
local BANDIT_CONFIRM = 3              -- seconds before a shot bandit still standing gets deleted
local BANDIT_RETRIES = 3
local ANNOUNCE_SECONDS = 30
local DRY_WARN_SECONDS = 120          -- "out of ammo" warning at most this often per camp

local POST_OFFSET = 32                -- post centers sit this far from the zone center on each axis
local POST_SIZE = { 4, 4 }            -- guard tower footprint: 3x3 base plus its south/east walls
local POST_SEARCH = 12                -- tiles to look around the ideal spot for a clear, off-road footprint
local BUILD_PLAYER_RANGE = 120
local BUILD_CHECK_SECONDS = 10
local POSTS = { { "NE", 1, -1 }, { "NW", -1, -1 }, { "SE", 1, 1 }, { "SW", -1, 1 } }
local KEY = "PESentries"

local function log(msg) print("[PE-Sentry] " .. msg) end
local function say(msg) print("[PE-Say] " .. msg) end
local function nowSec() return getTimestampMs() / 1000 end

local function heat() return PEDinoHeat end
local function campName(idx)
    local h = heat()
    return (h and h.CAMP_NAMES and h.CAMP_NAMES[idx]) or ("Zone " .. tostring(idx))
end

-- Announcements speak for the camp's team (the user's wording, 2026-09-28): "Alpha Team killed a raptor".
-- The team name is the camp name without a leading "Zone "/"Fort "/"Camp ".
local function teamName(idx)
    local n = campName(idx)
    n = n:gsub("^Zone ", ""):gsub("^Fort ", ""):gsub("^Camp ", "")
    return n .. " Team"
end

local function data()
    local md = ModData.getOrCreate(KEY)
    md.zones = md.zones or {}
    return md
end

-- Per-camp runtime state (not persisted).
local camps = {}
local function camp(idx)
    local c = camps[idx]
    if not c then
        c = { nextShot = 0, charges = PRESSURE_CHARGES, rechargeAt = 0, pending = {}, linePending = {}, lastAnnounce = 0, lastDry = 0, kills = 0 }
        camps[idx] = c
    end
    return c
end

local seen = setmetatable({}, { __mode = "k" })       -- intruder -> first second seen in a core
local claimed = setmetatable({}, { __mode = "k" })    -- wandering dino -> second claimed from evictCore
local banditShot = setmetatable({}, { __mode = "k" }) -- bandit -> { at, tries }
local banditGaveUp = setmetatable({}, { __mode = "k" }) -- bandits that survived every removal request

local function tally(idx, what)
    local p = camp(idx).pending
    p[what] = (p[what] or 0) + 1
end

-- A lamp-gun kill is announced for the nearest camp's defense line (the user wants players to see the
-- safe zones being defended), batched with the camp's own announcements.
local function tallyLine(x, y, what)
    local h = heat()
    local idx = h and h.nearestZone and h.nearestZone(x, y)
    if not idx then return end
    local p = camp(idx).linePending
    p[what] = (p[what] or 0) + 1
end

local function dinoLabel(a)
    local ok, t = pcall(function() return a:getAnimalType() end)
    t = ok and tostring(t) or "dino"
    local names = { vraptor = "raptor", vpachy = "pachy", vcarno = "carno", vstego = "stego", vanky = "anky", vtrex = "T-Rex" }
    return names[t:lower()] or t
end

local function isDino(a)
    return a and not a:isDead() and VDinoSpecies and VDinoSpecies.isDinosaur and VDinoSpecies.isDinosaur(a)
end

-- Lamp guns (the user's idea, 2026-09-28): every lit lamp of a checkpoint or gate (PE_DefenseLine's global
-- ModData PELights) is secretly a gun. A dino (not one steered at a camp by a hunt or raid) or a hostile
-- bandit that stays within TURRET_RANGE of one for TURRET_REACT seconds is shot, one shot per lamp every
-- TURRET_GAP seconds; kills are announced as the nearest camp's "defense line". Every sentry shot (camp kills too) plays from the
-- nearest lamp: players within SHOT_HEAR_RANGE get a "ZEM shot" server command and the map mod's
-- ZEM_Lights.lua plays a rifle shot with a muzzle flash there.
local TURRET_RANGE = 15
local TURRET_REACT = 1
local TURRET_GAP = 2
local SHOT_FROM_RANGE = 60            -- a camp kill uses the nearest lamp within this for its shot
local SHOT_HEAR_RANGE = 100
local lampIndex, lampIndexAt = {}, -999
local lampNext = {}                   -- lamp key -> second it may fire again

local function refreshLamps(now)
    if now - lampIndexAt < 10 then return end
    lampIndexAt = now
    local ld = ModData.getOrCreate("PELights")
    lampIndex = {}
    for key in pairs(type(ld.lamps) == "table" and ld.lamps or {}) do
        local x, y, z = tostring(key):match("^(-?%d+),(-?%d+),(-?%d+)$")
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        if x then
            local b = math.floor(x / 32) .. "," .. math.floor(y / 32)
            lampIndex[b] = lampIndex[b] or {}
            table.insert(lampIndex[b], { x = x, y = y, z = z, key = key })
        end
    end
end

local function nearestLamp(x, y, range)
    local bx, by = math.floor(x / 32), math.floor(y / 32)
    local best, bestD = nil, range * range
    local reach = math.ceil(range / 32)
    for i = -reach, reach do
        for j = -reach, reach do
            for _, l in ipairs(lampIndex[(bx + i) .. "," .. (by + j)] or {}) do
                local d = (l.x - x) ^ 2 + (l.y - y) ^ 2
                if d <= bestD then best, bestD = l, d end
            end
        end
    end
    return best
end

local function shotEffect(x, y)
    local l = nearestLamp(x, y, SHOT_FROM_RANGE)
    if not l then return end
    local players = getOnlinePlayers()
    for i = 0, players and players:size() - 1 or -1 do
        local p = players:get(i)
        if p and (p:getX() - l.x) ^ 2 + (p:getY() - l.y) ^ 2 <= SHOT_HEAR_RANGE * SHOT_HEAR_RANGE then
            pcall(function() sendServerCommand(p, "ZEM", "shot", { x = l.x, y = l.y, z = l.z }) end)
        end
    end
end

local ourKills = setmetatable({}, { __mode = "k" })   -- dinos our guns killed (OnCharacterDeath skips them)

local function killDino(a, idx, why)
    ourKills[a] = true
    local label = dinoLabel(a)
    local x, y = math.floor(a:getX()), math.floor(a:getY())
    shotEffect(x, y)
    local ok = VDinoDeath and VDinoDeath.finalize and pcall(VDinoDeath.finalize, a, nil)
    if not ok then pcall(function() a:setHealth(0) end) end
    if idx then
        tally(idx, label)
        camp(idx).kills = camp(idx).kills + 1
    else
        tallyLine(x, y, label)
    end
    log(string.format("%s: shot %s %s at %d,%d", idx and campName(idx) or "lamp gun", why, label, x, y))
end

-- Called by PE_DinoHeat.evictCore for each wandering dino inside a core (keep-out applies).
-- Returns true while the sentries own it; false tells evictCore to despawn it the old way.
local function claim(a)
    local now = nowSec()
    claimed[a] = claimed[a] or now
    return now - claimed[a] < CLAIM_FALLBACK
end

-- Bandits ---------------------------------------------------------------------------------------
local function banditBrain(z)
    if GetBanditClusterData then
        local id = z:getPersistentOutfitID()
        local ok, gmd = pcall(GetBanditClusterData, id)
        if ok and type(gmd) == "table" and gmd[id] ~= nil then return gmd[id] end
    end
    local md = z:getModData()
    return md and md.brain
end

local function isHostileBandit(z)
    local b = banditBrain(z)
    return b ~= nil and (b.hostile == true or b.hostileP == true)
end

-- Live test 2026-09-28: a server-side Kill/setHealth(0) does NOT stick on a bandit (the client that
-- simulates it restores its health and it keeps walking, even flagged dead). So the shot goes
-- straight to the RCON delete (radius 1 catches a bandit that just took a step); the Kill is only
-- kept so the server stops treating it as a live threat meanwhile. It is tracked until it has left
-- the zombie list, re-requested every BANDIT_CONFIRM seconds, and counted once.
-- Live test #2: the server's copy of a client-simulated bandit can trail it by several tiles, so a
-- radius-1 delete missed a walking bandit 3 times while a radius-12 one got it. The radius grows with
-- each request; RCON removezombies clears a square of every zombie within the radius, so the radius
-- is capped one tile short of the nearest friendly bandit (0 = only the bandit's own square).
local REMOVE_RADII = { 3, 6, 10, 12 }
local friendlies = {}                 -- friendly bandits seen this tick (refreshed in engage)

local function removeRequest(z, try)
    local x, y, zz = math.floor(z:getX()), math.floor(z:getY()), math.floor(z:getZ())
    local r = REMOVE_RADII[math.min(try or 1, #REMOVE_RADII)]
    for _, f in ipairs(friendlies) do
        if math.floor(f:getZ()) == zz then
            local d = math.max(math.abs(math.floor(f:getX()) - x), math.abs(math.floor(f:getY()) - y))
            if d - 1 < r then r = math.max(0, d - 1) end
        end
    end
    print(string.format("[PE-Zed] %d %d %d %d", x, y, zz, r))
end

local function shootBandit(z, idx)
    local x, y = math.floor(z:getX()), math.floor(z:getY())
    shotEffect(x, y)
    pcall(function() z:setHealth(0) end)
    pcall(function() z:Kill(nil) end)
    removeRequest(z, 1)
    banditShot[z] = { at = nowSec(), tries = 0 }
    if idx then
        tally(idx, "bandit")
        camp(idx).kills = camp(idx).kills + 1
    else
        tallyLine(x, y, "bandit")
    end
    log(string.format("%s: shot hostile bandit at %d,%d", idx and campName(idx) or "lamp gun", x, y))
end

local function confirmBandits(now, present)
    for z, s in pairs(banditShot) do
        if not present[z] then
            banditShot[z] = nil
        elseif now - s.at >= BANDIT_CONFIRM then
            if s.tries >= BANDIT_RETRIES then
                banditShot[z], banditGaveUp[z] = nil, true
                log(string.format("bandit at %d,%d survived %d removal requests; giving up", math.floor(z:getX()), math.floor(z:getY()), s.tries))
            else
                s.tries, s.at = s.tries + 1, now
                removeRequest(z, s.tries + 1)
                log(string.format("bandit still standing at %d,%d; removal request %d", math.floor(z:getX()), math.floor(z:getY()), s.tries + 1))
            end
        end
    end
end

-- Main loop -------------------------------------------------------------------------------------
local function coreOf(x, y)
    local h = heat()
    local idx, d = h.nearestZone(x, y)
    if d < CORE then return idx end
    return nil
end

local function engage(now)
    local h = heat()
    local cell = getCell()
    if not cell then return end

    refreshLamps(now)

    -- Pressure pools recharge.
    for idx in pairs(h.ZONES or {}) do
        local c = camp(idx)
        if c.charges < PRESSURE_CHARGES and now >= c.rechargeAt then
            c.charges = c.charges + 1
            c.rechargeAt = now + PRESSURE_RECHARGE
        end
    end

    local animals = cell:getAnimals()
    for i = animals and animals:size() - 1 or -1, 0, -1 do
        local a = animals:get(i)
        if isDino(a) then
            local idx = coreOf(a:getX(), a:getY())
            if not idx then
                claimed[a] = nil
                local l = h.keepOutApplies(a, math.floor(now)) and nearestLamp(a:getX(), a:getY(), TURRET_RANGE)
                if not l then
                    seen[a] = nil
                else
                    seen[a] = seen[a] or now
                    if now - seen[a] >= TURRET_REACT and now >= (lampNext[l.key] or 0) then
                        lampNext[l.key] = now + TURRET_GAP
                        killDino(a, nil, "near lamp " .. l.key)
                    end
                end
            else
                seen[a] = seen[a] or now
                local c = camp(idx)
                if h.keepOutApplies(a, math.floor(now)) then
                    if now - seen[a] >= REACT_SECONDS and now >= c.nextShot then
                        c.nextShot = now + SHOT_GAP_SECONDS
                        killDino(a, idx, "intruding")
                    end
                elseif now - seen[a] >= PRESSURE_REACT then
                    if c.charges > 0 then
                        c.charges = c.charges - 1
                        if c.rechargeAt < now then c.rechargeAt = now + PRESSURE_RECHARGE end
                        killDino(a, idx, "hunting")
                    elseif now - c.lastDry >= DRY_WARN_SECONDS then
                        c.lastDry = now
                        say(teamName(idx) .. " is reloading - the pack is inside the wire!")
                    end
                end
            end
        end
    end

    local zombies = cell:getZombieList()
    local present = {}
    friendlies = {}
    for i = zombies and zombies:size() - 1 or -1, 0, -1 do
        local z = zombies:get(i)
        if z then
            present[z] = true
            if not z:isDead() then
                local b = banditBrain(z)
                if b and not (b.hostile == true or b.hostileP == true) then friendlies[#friendlies + 1] = z end
            end
        end
        if z and not z:isDead() and not banditShot[z] and not banditGaveUp[z] and isHostileBandit(z) then
            local idx = coreOf(z:getX(), z:getY())
            if not idx then
                local l = nearestLamp(z:getX(), z:getY(), TURRET_RANGE)
                if not l then
                    seen[z] = nil
                else
                    seen[z] = seen[z] or now
                    if now - seen[z] >= TURRET_REACT and now >= (lampNext[l.key] or 0) then
                        lampNext[l.key] = now + TURRET_GAP
                        shootBandit(z, nil)
                    end
                end
            else
                seen[z] = seen[z] or now
                local c = camp(idx)
                if now - seen[z] >= REACT_SECONDS and now >= c.nextShot then
                    c.nextShot = now + SHOT_GAP_SECONDS
                    shootBandit(z, idx)
                end
            end
        end
    end
    confirmBandits(now, present)

    for idx, c in pairs(camps) do
        if now - c.lastAnnounce >= ANNOUNCE_SECONDS then
            -- (Kahlua has no next(), so collect the tallies and test the count instead)
            -- One message per team: its sentries' and its defense line's kills together,
            -- e.g. "Alpha Team killed a raptor" / "Alpha Team killed 2 raptors and a bandit".
            local counts, total = {}, 0
            for _, t in ipairs({ c.pending, c.linePending }) do
                for what, n in pairs(t) do counts[what] = (counts[what] or 0) + n; total = total + n end
            end
            if total > 0 then
                local parts = {}
                for what, n in pairs(counts) do
                    if n == 1 then
                        parts[#parts + 1] = (what:sub(1, 1):match("[aeiouAEIOU]") and "an " or "a ") .. what
                    else
                        parts[#parts + 1] = n .. " " .. what .. (what:sub(-1) == "x" and "" or "s")
                    end
                end
                table.sort(parts)
                local text = parts[#parts]
                if #parts > 1 then text = table.concat(parts, ", ", 1, #parts - 1) .. " and " .. parts[#parts] end
                say(teamName(idx) .. " killed " .. text)
                c.pending, c.linePending, c.lastAnnounce = {}, {}, now
            end
        end
    end
end

-- Guard towers ------------------------------------------------------------------------------------
-- Four open stilt watchtowers per camp, on its diagonals (the user's design, 2026-09-28). Built from
-- vanilla pieces, all transmitted to clients. Relative to the tower origin (a 3x3 deck, squares 0..2):
--   z0, z1: a log corner post at each of the deck's four corners (the legs); the ground is left open.
--   z2:     wooden deck with railings that can't be hopped on all four sides. No roof.
-- Why open: v1 was a closed, doorless log box with a roofed deck, and the game draws sealed rooms and
-- roofed floors the player can't enter as solid black, behind wall cutaways (live test 2026-09-28).
-- No stairs or ladder and unhoppable railings keep players off it (they can walk underneath);
-- repairTick puts back any piece that has been smashed. Older posts migrate automatically: the
-- Bandits "MilitaryField" obstacle course (the very first version) and the v1 log box.
local WALL_N, WALL_W, WALL_SE = "walls_logs_19", "walls_logs_16", "walls_logs_3"
local FLOOR, PILLAR = "carpentry_02_56", "carpentry_02_59"   -- v1/v2 only
-- A flat roof top (flagged exterior + solidfloor): the game draws it from outside, where a floor tile
-- two storeys up counts as a hidden interior and renders black (live test v2, 2026-09-28).
local DECK = "roofs_01_22"
local RAIL_N, RAIL_W = "fixtures_railings_01_2", "fixtures_railings_01_5"
local SPAN = 3
local REPAIR_SECONDS = 300

-- v1: closed log box with a roofed deck. Kept only so migrateTick can remove it exactly.
local function towerLayoutV1()
    local parts = {}
    local function add(x, y, z, sprite) parts[#parts + 1] = { x = x, y = y, z = z, sprite = sprite } end
    for z = 0, 1 do
        for i = 0, SPAN - 1 do
            add(i, 0, z, WALL_N); add(i, SPAN, z, WALL_N)
            add(0, i, z, WALL_W); add(SPAN, i, z, WALL_W)
        end
        add(SPAN, SPAN, z, WALL_SE)
    end
    for x = 0, SPAN - 1 do
        for y = 0, SPAN - 1 do add(x, y, 2, FLOOR); add(x, y, 3, FLOOR) end
    end
    for i = 0, SPAN - 1 do
        add(i, 0, 2, RAIL_N); add(i, SPAN, 2, RAIL_N)
        add(0, i, 2, RAIL_W); add(SPAN, i, 2, RAIL_W)
    end
    for _, c in ipairs({ { 0, 0 }, { SPAN - 1, 0 }, { 0, SPAN - 1 }, { SPAN - 1, SPAN - 1 } }) do add(c[1], c[2], 2, PILLAR) end
    return parts
end

-- v2 (floor deck) and v3 (current, roof-top deck): open stilt watchtower.
local function towerLayout(deck)
    local parts = {}
    local function add(x, y, z, sprite) parts[#parts + 1] = { x = x, y = y, z = z, sprite = sprite } end
    -- a corner post sits on the north-west corner of its square, so the posts on squares (0|SPAN, 0|SPAN)
    -- stand at the four corners of the 3x3 deck
    for z = 0, 1 do
        for _, c in ipairs({ { 0, 0 }, { SPAN, 0 }, { 0, SPAN }, { SPAN, SPAN } }) do add(c[1], c[2], z, WALL_SE) end
    end
    for x = 0, SPAN - 1 do                     -- the deck first, so it sits under the railings
        for y = 0, SPAN - 1 do add(x, y, 2, deck) end
    end
    for i = 0, SPAN - 1 do
        add(i, 0, 2, RAIL_N); add(i, SPAN, 2, RAIL_N)
        add(0, i, 2, RAIL_W); add(SPAN, i, 2, RAIL_W)
    end
    return parts
end
local TOWER = towerLayout(DECK)
local TOWER_KIND = "tower3"
-- earlier versions by ModData kind: removed piece by piece and rebuilt as the current tower
local LEGACY = { tower = towerLayoutV1(), tower2 = towerLayout(FLOOR) }

-- The old obstacle course, recorded from the Bandits prefab so exactly its pieces can be removed.
local OLD_SIZE = { 11, 10 }
local function recordOldCourse()
    if not (BanditProc and BanditProc.MilitaryField and BanditBasePlacements) then return nil end
    local rec, saved = {}, {}
    for _, k in ipairs({ "IsoObject", "IsoThumpable" }) do
        saved[k] = BanditBasePlacements[k]
        BanditBasePlacements[k] = function(sprite, x, y, z)
            rec[#rec + 1] = { x = x, y = y, z = z or 0, sprite = sprite }
        end
    end
    local ok, err = pcall(BanditProc.MilitaryField, 0, 0, 0)
    for k, f in pairs(saved) do BanditBasePlacements[k] = f end
    if not ok then log("old course record failed: " .. tostring(err)) return nil end
    return rec
end

local NATURAL = { "e_", "vegetation_", "blends_natural", "f_", "d_" }
local function isNatural(o)
    if instanceof(o, "IsoTree") then return true end
    local spr = o:getSprite()
    local name = spr and spr:getName() or ""
    for _, pre in ipairs(NATURAL) do
        if name:sub(1, #pre) == pre then return true end
    end
    return false
end

-- A footprint square is usable when it is loaded, outdoors, dry, and holds nothing but floor and
-- plants (never anything a player built or placed).
local function squareOk(sq)
    if not sq or sq:getRoom() then return false end
    local props = sq:getProperties()
    if props and props:has(IsoFlagType.water) then return false end
    if sq:getMovingObjects():size() > 0 then return false end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        local spr = o:getSprite()
        local p = spr and spr:getProperties()
        local isFloor = p and p:has(IsoFlagType.solidfloor)
        if not isFloor and not isNatural(o) then return false end
    end
    return true
end

-- Roads: asphalt (floors_exterior_street_*) and gravel/dirt road overlays (blends_street_*).
local function isRoad(sq)
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local spr = objs:get(i):getSprite()
        if spr and (spr:getName() or ""):find("street") then return true end
    end
    return false
end

-- The legs stand at the deck's four corner points (corner posts on these squares). They must never be
-- on a road; the ground under the deck may be (a tower can straddle a road, the user's call).
local LEGS = { { 0, 0 }, { SPAN, 0 }, { 0, SPAN }, { SPAN, SPAN } }
local function legsOnRoad(ox, oy)
    local cell = getCell()
    for _, l in ipairs(LEGS) do
        local sq = cell:getGridSquare(ox + l[1], oy + l[2], 0)
        if sq and isRoad(sq) then return true end
    end
    return false
end

local function footprintOk(ox, oy)
    local cell = getCell()
    for dx = 0, POST_SIZE[1] - 1 do
        for dy = 0, POST_SIZE[2] - 1 do
            if not squareOk(cell:getGridSquare(ox + dx, oy + dy, 0)) then return false end
        end
    end
    return not legsOnRoad(ox, oy)
end

-- Nearest usable tower origin to a post's ideal spot, searched ring by ring in 1-tile steps.
local function findSite(zc, def)
    local cx, cy = zc[1] + def[2] * POST_OFFSET, zc[2] + def[3] * POST_OFFSET
    local bx, by = cx - math.floor(POST_SIZE[1] / 2), cy - math.floor(POST_SIZE[2] / 2)
    for r = 0, POST_SEARCH do
        for dx = -r, r do
            for dy = -r, r do
                if (math.abs(dx) == r or math.abs(dy) == r) and footprintOk(bx + dx, by + dy) then
                    return bx + dx, by + dy
                end
            end
        end
    end
    return nil
end

local function areaLoaded(ox, oy, w, h)
    local cell = getCell()
    return cell:getGridSquare(ox, oy, 0) ~= nil and cell:getGridSquare(ox + w - 1, oy, 0) ~= nil
        and cell:getGridSquare(ox, oy + h - 1, 0) ~= nil and cell:getGridSquare(ox + w - 1, oy + h - 1, 0) ~= nil
end

local function removeObject(sq, o)
    local ok = pcall(function() sq:transmitRemoveItemFromSquare(o) end)
    if not ok then pcall(function() sq:RemoveTileObject(o) end) end
end

local function clearPlants(sq)
    if not sq then return end
    local objs = sq:getObjects()
    for i = objs:size() - 1, 0, -1 do
        local o = objs:get(i)
        local spr = o:getSprite()
        local p = spr and spr:getProperties()
        if not (p and p:has(IsoFlagType.solidfloor)) and isNatural(o) then removeObject(sq, o) end
    end
end

local function squareAt(x, y, z)
    local cell = getCell()
    local sq = cell:getGridSquare(x, y, z)
    if not sq and z > 0 then
        local ok, made = pcall(function() return cell:createNewGridSquare(x, y, z, true) end)
        if ok then sq = made end
    end
    return sq
end

local function hasSprite(sq, sprite)
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local s = objs:get(i):getSprite()
        if s and s:getName() == sprite then return true end
    end
    return false
end

-- Places the tower (or, with onlyMissing, just the pieces that are gone). Returns placed, missed.
local function buildTower(ox, oy, onlyMissing)
    local cell = getCell()
    if not onlyMissing then
        for dx = 0, SPAN do
            for dy = 0, SPAN do clearPlants(cell:getGridSquare(ox + dx, oy + dy, 0)) end
        end
    end
    local placed, missed = 0, 0
    for _, p in ipairs(TOWER) do
        local sq = squareAt(ox + p.x, oy + p.y, p.z)
        if not sq then
            missed = missed + 1
        elseif not (onlyMissing and hasSprite(sq, p.sprite)) then
            local ok = pcall(function()
                local obj = IsoObject.new(sq, p.sprite, "")
                sq:AddTileObject(obj)
                obj:transmitCompleteItemToClients()
            end)
            if ok then placed = placed + 1 else missed = missed + 1 end
        end
    end
    return placed, missed
end

-- Removes exactly the old course's pieces (matched by sprite at their recorded squares).
local function clearOldCourse(ox, oy, layout)
    local cell = getCell()
    local removed = 0
    for _, p in ipairs(layout) do
        local sq = cell:getGridSquare(ox + p.x, oy + p.y, p.z)
        if sq then
            local objs = sq:getObjects()
            for i = objs:size() - 1, 0, -1 do
                local o = objs:get(i)
                local s = o:getSprite()
                if s and s:getName() == p.sprite then removeObject(sq, o); removed = removed + 1; break end
            end
        end
    end
    return removed
end

local function playerNear(x, y, range)
    local players = getOnlinePlayers()
    for i = 0, (players and players:size() or 0) - 1 do
        local p = players:get(i)
        local dx, dy = p:getX() - x, p:getY() - y
        if dx * dx + dy * dy <= range * range then return true end
    end
    return false
end

-- Gateways --------------------------------------------------------------------------------------------
-- The camps' visible defenses are gateways over the roads into each camp (the user's design,
-- 2026-09-28): a stack of logs on each road shoulder and a railed span across the road overhead, like a
-- wall the road passes through. Wherever a road crosses a square ring GATE_RING tiles out from the
-- zone center (outside the 40x40 safehouse, inside the 75-tile sentry core) a gate goes up; roads wider
-- than GATE_MAX_ROAD (highways) are skipped. The span sits on level GATE_Z, so the legs are three
-- storeys of logs and even a T-Rex clears it (dinos aren't blocked by upper floors anyway). No stairs or
-- ladder; repairs put smashed pieces back. The 4 diagonal towers of earlier versions are retired.
local GATE_RING = 40
local GATE_MAX_ROAD = 8              -- the user's cap (raised from 6 on 2026-09-28)
local GATE_SCAN_VER = 3              -- bump to rescan every ring side (existing gates are kept, never doubled)
local GATE_OWNER = "admin"           -- each gate is its own safehouse: no fire, no dismantling by others (set to your admin's username)
local GATE_Z = 3
local GATE_SHIFT = 3                  -- try moving the span this far along the road to find clear legs
local SIDES = { "N", "S", "W", "E" }

local function roadAt(x, y)
    local sq = getCell():getGridSquare(x, y, 0)
    return sq ~= nil and isRoad(sq)
end

-- g = { axis = "x" (a north-south road, span along x on row `line`) or "y" (east-west road, span along y
-- on column `line`), a..b = the road squares it spans }. One grass tile of margin on each side.
local function gateLegs(g)
    local lo, hi = g.a - 1, g.b + 1
    if g.axis == "x" then
        return { { lo, g.line }, { lo, g.line + 1 }, { hi + 1, g.line }, { hi + 1, g.line + 1 } }
    end
    return { { g.line, lo }, { g.line + 1, lo }, { g.line, hi + 1 }, { g.line + 1, hi + 1 } }
end

local function gateLayout(g)
    local parts = {}
    local function add(x, y, z, sprite) parts[#parts + 1] = { x = x, y = y, z = z, sprite = sprite } end
    local lo, hi = g.a - 1, g.b + 1
    -- legs: a corner post on each leg square (it stands on the square's NW corner), GATE_Z storeys high,
    -- two posts deep per side so each end reads as a solid stack
    for z = 0, GATE_Z - 1 do
        for _, l in ipairs(gateLegs(g)) do add(l[1], l[2], z, WALL_SE) end
    end
    if g.axis == "x" then
        local y = g.line
        for x = lo, hi do add(x, y, GATE_Z, DECK) end                 -- deck first, under the railings
        for x = lo, hi do add(x, y, GATE_Z, RAIL_N); add(x, y + 1, GATE_Z, RAIL_N) end
        add(lo, y, GATE_Z, RAIL_W); add(hi + 1, y, GATE_Z, RAIL_W)
    else
        local x = g.line
        for y = lo, hi do add(x, y, GATE_Z, DECK) end
        for y = lo, hi do add(x, y, GATE_Z, RAIL_W); add(x + 1, y, GATE_Z, RAIL_W) end
        add(x, lo, GATE_Z, RAIL_N); add(x, hi + 1, GATE_Z, RAIL_N)
    end
    return parts
end

local function placeParts(parts, onlyMissing)
    local placed, missed = 0, 0
    for _, p in ipairs(parts) do
        local sq = squareAt(p.x, p.y, p.z)
        if not sq then
            missed = missed + 1
        elseif not (onlyMissing and hasSprite(sq, p.sprite)) then
            local ok = pcall(function()
                local obj = IsoObject.new(sq, p.sprite, "")
                sq:AddTileObject(obj)
                obj:transmitCompleteItemToClients()
            end)
            if ok then placed = placed + 1 else missed = missed + 1 end
        end
    end
    return placed, missed
end

-- The road run through (line, mid) on the given axis, or nil if mid isn't road there.
local function runAt(axis, line, mid)
    local function at(i) if axis == "x" then return roadAt(i, line) else return roadAt(line, i) end end
    if not at(mid) then return nil end
    local a, b = mid, mid
    while at(a - 1) and mid - a < 20 do a = a - 1 end
    while at(b + 1) and b - mid < 20 do b = b + 1 end
    return a, b
end

local function legsOk(g)
    local cell = getCell()
    for _, l in ipairs(gateLegs(g)) do
        local sq = cell:getGridSquare(l[1], l[2], 0)
        if not squareOk(sq) or isRoad(sq) then return false end
    end
    -- the margin squares under the span ends must not be road either
    local lo, hi = g.a - 1, g.b + 1
    if g.axis == "x" then return not roadAt(lo, g.line) and not roadAt(hi, g.line) end
    return not roadAt(g.line, lo) and not roadAt(g.line, hi)
end

-- Scan one side of the ring; returns a list of gates (possibly empty) or nil if not all loaded.
local function scanSideAt(zc, side, R)
    local cx, cy = zc[1], zc[2]
    local axis = (side == "N" or side == "S") and "x" or "y"
    local line = (side == "N" and cy - R) or (side == "S" and cy + R) or (side == "W" and cx - R) or (cx + R)
    local from = axis == "x" and cx - R or cy - R
    local cell = getCell()
    for i = from, from + 2 * R do
        local sq = axis == "x" and cell:getGridSquare(i, line, 0) or cell:getGridSquare(line, i, 0)
        if not sq then return nil end
    end
    local gates, i, skippedWide, loggedWide = {}, from, false, false
    while i <= from + 2 * R do
        local a, b = runAt(axis, line, i)
        if a then
            local mid = math.floor((a + b) / 2)
            if b - a + 1 <= GATE_MAX_ROAD then
                local chosen
                for k = 0, GATE_SHIFT * 2 do
                    local shift = (k % 2 == 0) and math.floor(k / 2) or -math.floor((k + 1) / 2)
                    local sa, sb = runAt(axis, line + shift, mid)
                    if sa and sb - sa + 1 <= GATE_MAX_ROAD then
                        local g = { axis = axis, a = sa, b = sb, line = line + shift, side = side }
                        if legsOk(g) then chosen = g break end
                    end
                end
                if chosen then gates[#gates + 1] = chosen
                else log(string.format("gate skipped: road at side %s (%d-%d on line %d) has no clear shoulders", side, a, b, line)) end
            elseif b - a + 1 > 16 then
                skippedWide = true            -- a road lying along the ring line (not crossing it): shift the line
            elseif not loggedWide then
                loggedWide = true             -- a wide crossing road (highway): skipped, per the user's cap
                log(string.format("gate skipped: road at side %s is %d wide (max %d)", side, b - a + 1, GATE_MAX_ROAD))
            end
            i = b + 1
        else
            i = i + 1
        end
    end
    return gates, skippedWide
end

-- When the ring line runs along a street (a town grid: Alpha's north and west sides), move that side's
-- line a few tiles in or out to the nearest one that crosses roads instead of lying on one.
local RING_SHIFTS = { 0, 2, -2, 4, -4, 6, -6, 8, -8 }
local function scanSide(zc, side)
    local best
    for _, d in ipairs(RING_SHIFTS) do
        local gates, alongRoad = scanSideAt(zc, side, GATE_RING + d)
        if not gates then return nil end              -- not loaded yet
        if not alongRoad then
            if d ~= 0 then log(string.format("side %s: ring line lay along a road; using ring %d instead of %d", side, GATE_RING + d, GATE_RING)) end
            return gates
        end
        best = best or gates
    end
    log(string.format("gate skipped: side %s runs along a road at every ring from %d to %d", side, GATE_RING - 8, GATE_RING + 8))
    return best
end

-- Each gate is also a small safehouse (the user's request): SafehouseAllowFire=false keeps fire out,
-- and only the owner/admins may dismantle inside it. Trespass is allowed on Evolved, so traffic passes.
local function gateRect(g)
    if g.style == "sandbag" and g.u1 then           -- the checkpoint: both walls (v = line .. line + 3) and nests
        if g.axis == "x" then return g.u1, g.line, g.u2 - g.u1 + 2, 4 end
        return g.line, g.u1, 4, g.u2 - g.u1 + 2
    end
    local lo, hi = g.a - 1, g.b + 1
    if g.axis == "x" then return lo, g.line, hi + 2 - lo, 2 end
    return g.line, lo, 2, hi + 2 - lo
end

local function ensureSafehouse(g, idx)
    if g.safehouse then return end
    local x, y, w, h = gateRect(g)
    local ok, existing = pcall(function() return SafeHouse.getSafeHouse(x, y, w, h) end)
    if ok and existing then g.safehouse = true return end
    local ok2, sh = pcall(function() return SafeHouse.addSafeHouse(x, y, w, h, GATE_OWNER) end)
    if ok2 and sh then
        pcall(function() sh:setTitle(campName(idx) .. " Gate " .. tostring(g.side)) end)
        g.safehouse = true
        log(string.format("%s gate %s: safehouse %d,%d %dx%d owner=%s", campName(idx), g.side, x, y, w, h, GATE_OWNER))
    else
        log(string.format("%s gate %s: safehouse FAILED: %s", campName(idx), g.side, tostring(sh)))
    end
end

-- Sandbag checkpoints (the user's call, 2026-09-28: "just sandbags instead of these wood towers"). Each
-- gate becomes the same checkpoint the defense lines use (PEDefenseLine.checkpointParts in
-- PE_DefenseLine.lua): two sandbag walls across the road and a lit nest on each shoulder. An old log gate
-- loses its exact pieces and its safehouse strip first; the new, larger safehouse follows in
-- ensureSafehouse. g.style = "sandbag", g.parts = the pieces standing (for repair).
local function gateLoaded(g)
    local cell = getCell()
    local function sq(u, v) if g.axis == "x" then return cell:getGridSquare(u, v, 0) end return cell:getGridSquare(v, u, 0) end
    return sq(g.a - 6, g.line - 1) ~= nil and sq(g.b + 7, g.line - 1) ~= nil
        and sq(g.a - 6, g.line + 4) ~= nil and sq(g.b + 7, g.line + 4) ~= nil
end

-- Ring gates in the gaps (the user's design, 2026-09-28): a single-row gate (PEDefenseLine.planSegment)
-- at these offsets along each side of the gate ring, unless a road checkpoint is within CAMP_SEG_CLEAR.
local CAMP_SEG_OFFSETS = { -30, -10, 10, 30 }
local CAMP_SEG_CLEAR = 10
local function nearGate(gates, x, y)
    for _, g in ipairs(gates) do
        local gx, gy
        if g.axis == "x" then gx, gy = (g.a + g.b) / 2, g.line + 1.5 else gx, gy = g.line + 1.5, (g.a + g.b) / 2 end
        local half = (g.b - g.a) / 2 + 5
        if math.abs(gx - x) <= half + CAMP_SEG_CLEAR and math.abs(gy - y) <= half + CAMP_SEG_CLEAR then return true end
    end
    return false
end

local SANDBAG_VER = 2                 -- bump to rebuild every camp checkpoint with the current layout (2: end lamps)
local function toSandbag(g, idx, hadLogGate)
    local DL = PEDefenseLine
    if not (DL and DL.checkpointParts and DL.placeAll) then return false end
    if g.style == "sandbag" then                  -- an older sandbag layout: take it down first
        DL.clearParts(g.parts)
        local x, y, w, h = gateRect(g)
        local okS, sh = pcall(function() return SafeHouse.getSafeHouse(x, y, w, h) end)
        if okS and sh then pcall(function() SafeHouse.removeSafeHouse(sh) end) end
        g.safehouse, g.parts, g.u1, g.u2 = nil, {}, nil, nil
        hadLogGate = false
    end
    if hadLogGate then
        local removed = clearOldCourse(0, 0, gateLayout(g))
        local x, y, w, h = gateRect(g)
        local okS, sh = pcall(function() return SafeHouse.getSafeHouse(x, y, w, h) end)
        if okS and sh then pcall(function() SafeHouse.removeSafeHouse(sh) end) end
        g.safehouse = nil
        log(string.format("%s gate %s %d-%d: log gate taken down (%d pieces)", campName(idx), g.side, g.a, g.b, removed))
    end
    local plan, _, _, u1, u2 = DL.checkpointParts(g.axis, g.line, g.a, g.b)
    g.style, g.sandVer = "sandbag", SANDBAG_VER
    if not plan then
        g.parts = {}
        log(string.format("%s gate %s %d-%d: no room for a sandbag checkpoint", campName(idx), g.side, g.a, g.b))
        return true
    end
    g.parts = DL.placeAll(plan)
    g.u1, g.u2 = u1, u2
    log(string.format("%s gate %s %d-%d: sandbag checkpoint built (%d pieces)", campName(idx), g.side, g.a, g.b, #g.parts))
    return true
end

local function overlapsExisting(gates, g)
    for _, e in ipairs(gates) do
        if e.side == g.side and e.axis == g.axis and math.abs(e.line - g.line) <= GATE_SHIFT * 2
                and e.a <= g.b + 1 and g.a <= e.b + 1 then
            return true
        end
    end
    return false
end

-- Palisade ------------------------------------------------------------------------------------------
-- A log wall round each camp on the gate ring (the user's design, 2026-09-28), so the gates are the
-- way in. Walls sit on the edges of the ring box x0..x1, y0..y1 (GATE_RING from the zone center):
-- WallN on the north/south edges, WallW on the west/east edges, the unclimbable walls_logs pieces.
-- The wall skips road squares (roads always pass: under a gate, or open when too wide for one),
-- each gate's footprint, and any square with a building, water or something a player placed.
-- A side with no road gate gets a log door in its middle so people on foot can always get in and out.
-- Each side is a thin safehouse (no fire, no dismantling) and the repair pass covers the wall too.
local WALL_LEVELS = 1                 -- storeys of fence
local DOOR_N, DOOR_W = "walls_logs_41", "walls_logs_40"
-- v2 (2026-09-28): a see-through fence that can't be climbed (CantClimb + Wall*Trans; only spears
-- attack through). v1 was two storeys of solid log wall: the game blacks out everything a player can't
-- see, so the camp read as a black void from outside (and the gate decks went black behind it).
local WALL_VER = 2
-- The user decided against walls (2026-09-28): gates over the roads only, and a dino that slips in
-- between is the danger. With this off, existing wall sides are torn down (pieces, door, safehouse strip).
local WALLS_ENABLED = false
local FENCE_N, FENCE_W, FENCE_POST = { "fencing_01_48", "fencing_01_49" }, { "fencing_01_50", "fencing_01_51" }, "fencing_01_53"

local function ringBox(zc)
    return zc[1] - GATE_RING, zc[2] - GATE_RING, zc[1] + GATE_RING, zc[2] + GATE_RING
end

-- The wall slots of one side: { x, y, sprite, door } for every square along it.
local function sideSlots(zc, side)
    local x0, y0, x1, y1 = ringBox(zc)
    local slots = {}
    if side == "N" or side == "S" then
        local y = side == "N" and y0 or y1
        for x = x0, x1 - 1 do slots[#slots + 1] = { x = x, y = y, along = x, sprite = FENCE_N[x % 2 + 1], door = DOOR_N, north = true } end
    else
        local x = side == "W" and x0 or x1
        for y = y0, y1 - 1 do slots[#slots + 1] = { x = x, y = y, along = y, sprite = FENCE_W[y % 2 + 1], door = DOOR_W, north = false } end
    end
    return slots
end

local function inGate(gates, side, along)
    for _, g in ipairs(gates) do
        if g.side == side and along >= g.a - 1 and along <= g.b + 1 then return true end
    end
    return false
end

local function slotOk(sq)
    if not sq or sq:getRoom() or isRoad(sq) then return false end
    local props = sq:getProperties()
    if props and props:has(IsoFlagType.water) then return false end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        local spr = o:getSprite()
        local p = spr and spr:getProperties()
        if not (p and p:has(IsoFlagType.solidfloor)) and not isNatural(o) then return false end
    end
    return true
end

local function placeDoor(sq, sprite, north)
    local ok = pcall(function()
        local door = IsoDoor.new(getCell(), sq, sprite, north)
        sq:AddSpecialObject(door)
        door:transmitCompleteItemToClients()
    end)
    return ok
end

local function wallRect(zc, side)
    local x0, y0, x1, y1 = ringBox(zc)
    if side == "N" then return x0, y0, x1 - x0, 1 end
    if side == "S" then return x0, y1, x1 - x0, 1 end
    if side == "W" then return x0, y0, 1, y1 - y0 end
    return x1, y0, 1, y1 - y0
end

-- Builds one side (all its squares must be loaded). Returns the record stored in ModData.
local function buildWallSide(idx, zc, side, gates)
    local cell = getCell()
    local rec = { side = side, pieces = {}, door = nil, ver = WALL_VER }
    local usable = {}
    for _, s in ipairs(sideSlots(zc, side)) do
        if not inGate(gates, side, s.along) then
            local sq = cell:getGridSquare(s.x, s.y, 0)
            if slotOk(sq) then usable[#usable + 1] = s end
        end
    end
    -- a side without a road gate gets a door at the usable slot nearest its middle
    local hasGate = false
    for _, g in ipairs(gates) do if g.side == side then hasGate = true end end
    local doorSlot
    if not hasGate and #usable > 0 then
        local mid = (side == "N" or side == "S") and zc[1] or zc[2]
        for _, s in ipairs(usable) do
            if not doorSlot or math.abs(s.along - mid) < math.abs(doorSlot.along - mid) then doorSlot = s end
        end
    end
    local placed = 0
    for _, s in ipairs(usable) do
        local sq = cell:getGridSquare(s.x, s.y, 0)
        clearPlants(sq)
        for z = 0, WALL_LEVELS - 1 do
            if z == 0 and s == doorSlot then
                if placeDoor(sq, s.door, s.north) then placed = placed + 1 end
                rec.door = { x = s.x, y = s.y, sprite = s.door, north = s.north }
            else
                rec.pieces[#rec.pieces + 1] = { x = s.x, y = s.y, z = z, sprite = s.sprite }
            end
        end
    end
    -- the south-east corner post closes the box where the east and south walls meet
    if side == "E" then
        local x0, y0, x1, y1 = ringBox(zc)
        local sq = cell:getGridSquare(x1, y1, 0)
        if slotOk(sq) then
            for z = 0, WALL_LEVELS - 1 do rec.pieces[#rec.pieces + 1] = { x = x1, y = y1, z = z, sprite = FENCE_POST } end
        end
    end
    local p2 = placeParts(rec.pieces, false)
    placed = placed + p2
    -- safehouse strip
    local x, y, w, h = wallRect(zc, side)
    local okE, existing = pcall(function() return SafeHouse.getSafeHouse(x, y, w, h) end)
    if not (okE and existing) then
        local ok, sh = pcall(function() return SafeHouse.addSafeHouse(x, y, w, h, GATE_OWNER) end)
        if ok and sh then pcall(function() sh:setTitle(campName(idx) .. " Wall " .. side) end) end
    end
    log(string.format("%s wall %s built: %d pieces over %d of %d squares%s", campName(idx), side, placed,
        #usable, #sideSlots(zc, side), rec.door and string.format(", door at %d,%d", rec.door.x, rec.door.y) or ""))
    return rec
end

local function repairWall(rec)
    local placed = placeParts(rec.pieces, true)
    if rec.door then
        local sq = getCell():getGridSquare(rec.door.x, rec.door.y, 0)
        -- an open door shows a different sprite, so look for any door object rather than the sprite
        local hasDoor = false
        if sq then
            local objs = sq:getObjects()
            for i = 0, objs:size() - 1 do if instanceof(objs:get(i), "IsoDoor") then hasDoor = true break end end
        end
        if sq and not hasDoor and placeDoor(sq, rec.door.sprite, rec.door.north) then placed = placed + 1 end
    end
    return placed
end

local function sideLoaded(zc, side)
    local cell = getCell()
    for _, s in ipairs(sideSlots(zc, side)) do
        if not cell:getGridSquare(s.x, s.y, 0) then return false end
    end
    return true
end

local oldLayout
local lastRepair = 0
local function buildTick()
    local h = heat()
    if not (h and h.ZONES) then return end
    oldLayout = oldLayout or recordOldCourse()
    local md = data()
    local now = nowSec()
    local repair = now - lastRepair >= REPAIR_SECONDS
    if repair then lastRepair = now end
    for idx, zc in ipairs(h.ZONES) do
        if playerNear(zc[1], zc[2], BUILD_PLAYER_RANGE) then
            md.zones[idx] = md.zones[idx] or {}
            local zd = md.zones[idx]
            zd.posts = zd.posts or {}
            zd.gates = zd.gates or {}
            zd.scanned = zd.scanned or {}
            if zd.scanVer ~= GATE_SCAN_VER then zd.scanned, zd.scanVer = {}, GATE_SCAN_VER end
            -- retire the diagonal towers of every earlier version, piece by piece
            local names = {}
            for name in pairs(zd.posts) do names[#names + 1] = name end
            for _, name in ipairs(names) do
                local rec = zd.posts[name]
                local layout, w, hgt
                if rec.kind == TOWER_KIND then layout, w, hgt = TOWER, SPAN + 1, SPAN + 1
                elseif LEGACY[rec.kind] then layout, w, hgt = LEGACY[rec.kind], SPAN + 1, SPAN + 1
                else layout, w, hgt = oldLayout, OLD_SIZE[1], OLD_SIZE[2] end
                if layout and areaLoaded(rec.x, rec.y, w, hgt) then
                    local removed = clearOldCourse(rec.x, rec.y, layout)
                    zd.posts[name] = nil
                    log(string.format("%s %s: diagonal %s retired (%d pieces removed)", campName(idx), name, tostring(rec.kind or "course"), removed))
                end
            end
            -- find the roads into the camp, one ring side at a time once it's loaded
            for _, side in ipairs(SIDES) do
                if not zd.scanned[side] then
                    local found = scanSide(zc, side)
                    if found then
                        zd.scanned[side] = true
                        for _, g in ipairs(found) do
                          if not overlapsExisting(zd.gates, g) then
                            g.built = now
                            zd.gates[#zd.gates + 1] = g
                            log(string.format("%s gate found on side %s over road %d-%d (line %d, axis %s)",
                                campName(idx), side, g.a, g.b, g.line, g.axis))
                          end
                        end
                    end
                end
            end
            for _, g in ipairs(zd.gates) do
                if (g.style ~= "sandbag" or g.sandVer ~= SANDBAG_VER) and gateLoaded(g) then
                    local hadLogGate = g.style ~= "sandbag" and g.built ~= now   -- found this tick = nothing standing yet
                    toSandbag(g, idx, hadLogGate)
                end
            end
            for _, g in ipairs(zd.gates) do if g.style == "sandbag" then ensureSafehouse(g, idx) end end
            -- the gaps between the roads: a single-row gate every CAMP_SEG_SPACING along each ring side
            zd.segs = zd.segs or {}
            local DL = PEDefenseLine
            if DL and DL.planSegment then
                for _, side in ipairs(SIDES) do
                    if zd.scanned[side] then
                        for _, off in ipairs(CAMP_SEG_OFFSETS) do
                            local key = side .. ":" .. off
                            if not zd.segs[key] then
                                local horizontal = side == "N" or side == "S"
                                local x = horizontal and zc[1] + off or (side == "W" and zc[1] - GATE_RING or zc[1] + GATE_RING)
                                local y = horizontal and (side == "N" and zc[2] - GATE_RING or zc[2] + GATE_RING) or zc[2] + off
                                if nearGate(zd.gates, x, y) then
                                    zd.segs[key] = { state = "none" }
                                else
                                    local plan, lx, ly = DL.planSegment(x, y, horizontal, zc)
                                    if plan then
                                        local parts = DL.placeAll(plan)
                                        zd.segs[key] = { state = "post", x = lx, y = ly, parts = parts }
                                        log(string.format("%s ring gate %s built at %d,%d (%d pieces)", campName(idx), key, lx, ly, #parts))
                                    elseif plan == nil then
                                        zd.segs[key] = { state = "none" }
                                    end
                                end
                            end
                        end
                    end
                end
            end
            -- palisade: each side once its gate scan is done and the whole side is loaded
            zd.walls = zd.walls or {}
            for _, side in ipairs(SIDES) do
                local rec = zd.walls[side]
                if rec and (rec.ver ~= WALL_VER or not WALLS_ENABLED) and sideLoaded(zc, side) then
                    local removed = clearOldCourse(0, 0, rec.pieces)      -- pieces hold absolute coordinates
                    if rec.door then
                        local sq = getCell():getGridSquare(rec.door.x, rec.door.y, 0)
                        local objs = sq and sq:getObjects()
                        for i = (objs and objs:size() or 0) - 1, 0, -1 do
                            if instanceof(objs:get(i), "IsoDoor") then removeObject(sq, objs:get(i)); removed = removed + 1 end
                        end
                    end
                    zd.walls[side] = nil
                    if WALLS_ENABLED then
                        log(string.format("%s wall %s: v%s removed (%d pieces), rebuilding as fence", campName(idx), side, tostring(rec.ver or 1), removed))
                    else
                        local x, y, w, h = wallRect(zc, side)
                        local okS, sh = pcall(function() return SafeHouse.getSafeHouse(x, y, w, h) end)
                        if okS and sh then pcall(function() SafeHouse.removeSafeHouse(sh) end) end
                        log(string.format("%s wall %s torn down (%d pieces%s)", campName(idx), side, removed, (okS and sh) and ", safehouse strip removed" or ""))
                    end
                end
            end
            for _, side in ipairs(SIDES) do
                if WALLS_ENABLED and zd.scanned[side] and not zd.walls[side] and sideLoaded(zc, side) then
                    zd.walls[side] = buildWallSide(idx, zc, side, zd.gates)
                end
            end
            if repair then
                for _, g in ipairs(zd.gates) do
                    if g.style == "sandbag" and gateLoaded(g) and PEDefenseLine and PEDefenseLine.repairParts then
                        local placed = PEDefenseLine.repairParts(g.parts)
                        if placed > 0 then log(string.format("%s gate %s %d-%d repaired: %d piece(s)", campName(idx), g.side, g.a, g.b, placed)) end
                    end
                end
                for key, sg in pairs(zd.segs or {}) do
                    if sg.state == "post" and PEDefenseLine and PEDefenseLine.repairParts
                            and getCell():getGridSquare(sg.x, sg.y, 0) then
                        local placed = PEDefenseLine.repairParts(sg.parts)
                        if placed > 0 then log(string.format("%s ring gate %s repaired: %d piece(s)", campName(idx), key, placed)) end
                    end
                end
                for side, rec in pairs(zd.walls) do
                    if sideLoaded(zc, side) then
                        local placed = repairWall(rec)
                        if placed > 0 then log(string.format("%s wall %s repaired: %d piece(s)", campName(idx), side, placed)) end
                    end
                end
            end
        end
    end
end

-- Wiring ------------------------------------------------------------------------------------------
local lastTick, lastBuild = 0, 0
Events.OnTick.Add(function()
    local now = nowSec()
    if now - lastTick < TICK_SECONDS then return end
    lastTick = now
    if not heat() then return end
    local ok, err = pcall(engage, now)
    if not ok then log("error: " .. tostring(err)) end
    if now - lastBuild >= BUILD_CHECK_SECONDS then
        lastBuild = now
        local okB, errB = pcall(buildTick)
        if not okB then log("build error: " .. tostring(errB)) end
    end
end)

-- Team kills: a team is everyone in the zone, sentries and players (the user, 2026-09-28). A dino or a
-- hostile bandit that dies inside a zone's safe radius and wasn't shot by our guns counts for that
-- zone's team too, in the same batched announcement.
Events.OnCharacterDeath.Add(function(c)
    local ok, err = pcall(function()
        if not c or ourKills[c] or banditShot[c] then return end
        local h = heat()
        if not (h and h.nearestZone and h.safeRadius) then return end
        local label
        if instanceof(c, "IsoAnimal") then
            if not (VDinoSpecies and VDinoSpecies.isDinosaur and VDinoSpecies.isDinosaur(c)) then return end
            label = dinoLabel(c)
        elseif instanceof(c, "IsoZombie") and isHostileBandit(c) then
            label = "bandit"
        else
            return
        end
        local x, y = c:getX(), c:getY()
        local idx, d = h.nearestZone(x, y)
        if not idx or d >= h.safeRadius() then return end
        tally(idx, label)
        log(string.format("%s: team kill, %s at %d,%d", campName(idx), label, math.floor(x), math.floor(y)))
    end)
    if not ok then log("team kill error: " .. tostring(err)) end
end)

PESentries = { claim = claim, CORE = CORE }

if PEAdminCommands then
    -- sentries: status of every camp's defenses
    PEAdminCommands.sentries = function()
        local md = data()
        local h = heat()
        for idx in ipairs(h and h.ZONES or {}) do
            local c = camp(idx)
            local built = {}
            for _, g in ipairs((md.zones[idx] or {}).gates or {}) do built[#built + 1] = string.format("%s:%d-%d@%d", g.side, g.a, g.b, g.line) end
            local scanned = {}
            for side in pairs((md.zones[idx] or {}).scanned or {}) do scanned[#scanned + 1] = side end
            table.sort(scanned)
            print(string.format("[PE-Admin] %s: gates %s (ring sides scanned: %s) | pressure charges %d/%d | kills this boot %d",
                campName(idx), #built > 0 and table.concat(built, " ") or "none", #scanned > 0 and table.concat(scanned, "") or "-",
                c.charges, PRESSURE_CHARGES, c.kills))
        end
    end
end

Events.OnServerStarted.Add(function()
    log(string.format("active: core %d tiles, wanderers shot after %ds, hunt/raid pool %d per %ds",
        CORE, REACT_SECONDS, PRESSURE_CHARGES, PRESSURE_RECHARGE))
end)
