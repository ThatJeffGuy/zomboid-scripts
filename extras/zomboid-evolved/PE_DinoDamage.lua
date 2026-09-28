-- Project Evolution dinosaur damage model (server-side only, outside the Lua checksum).
-- Replaces PE_CloseKillGuard.lua (2026-09-26). Theme: dinosaurs are used to claws and teeth but
-- have never seen guns, so melee is a slog (raptor 5-7 hits; was 7-10 until 2026-09-27, all melee
-- ranges scaled x5/7 then) and ranged is their weakness: guns and bows got ~25% stronger the same
-- day (raptor: gun 1-1.5 shots, bow 2-3 arrows; hits-to-kill may be fractional).
--
-- Every hit on a dinosaur takes a fixed share of its max health = 1 / hits-to-kill, where
-- hits-to-kill comes from the table below for that species and weapon class, interpolated by the
-- weapon's MaxDamage (stronger weapon -> low end of the range).
--   * melee: native damage is cancelled and the share applied directly. The B42 knife close kill
--     (chin stab; the engine multiplies it x1000 and it fires on any target when no zombies chase)
--     counts as CLOSE_KILL_HITS melee hits instead of an instant kill.
--   * guns and bows: the dino mod applies its own shot damage (Dino_FirearmRay); DELAY_MS later
--     this tops the damage up so the shot took at least its share (never less than the mod did).
-- The dino mod's toughness divides melee damage by the species health multiplier afterwards, so
-- melee chunks are pre-scaled by it. Other animals and players are untouched.
-- Log prefix "[PE-Damage]". Edit the canonical copy in config/presets/.
if isClient() then return end

-- hits to kill: { melee = {strong, weak}, gun = {strong, weak}, bow = {strong, weak} }
local HITS = {
    vraptor = { melee = { 5, 7 },   gun = { 1, 1.5 },   bow = { 2, 3 } },
    vpachy  = { melee = { 5, 7 },   gun = { 1, 1.5 },   bow = { 2, 4 } },
    vcarno  = { melee = { 7, 10 },  gun = { 1.5, 2 },   bow = { 4, 5 } },
    vstego  = { melee = { 10, 13 }, gun = { 2, 3 },     bow = { 5, 7 } },
    vanky   = { melee = { 11, 14 }, gun = { 2, 4 },     bow = { 6, 8 } },
    vtrex   = { melee = { 18, 21 }, gun = { 4, 6 },     bow = { 9, 11 } },
}
local DEFAULT_HITS = { melee = { 7, 10 }, gun = { 1.5, 2 }, bow = { 4, 5 } }
-- weapon MaxDamage that maps to the weak / strong end of each range
local DMG_SPAN = { melee = { 0.6, 3.0 }, gun = { 1.0, 2.2 }, bow = { 0.5, 1.4 } }
local CLOSE_KILL_HITS = 2          -- a chin stab is worth this many melee hits
local DETECT_RATIO = 100           -- melee hit >= this x weapon max damage = close kill (x1000)
local DELAY_MS = 350               -- ranged top-up runs after the mod's shot + toughness settle
local SHOT_DEDUPE_MS = 250         -- one ranged hit per shooter+target per window (pellets, echoes)

local LOG_ALL_HITS = false         -- true logs every hit on a dino (tuning aid)

local function log(msg) print("[PE-Damage] " .. msg) end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function nameOf(chr) return chr and chr.getUsername and tostring(chr:getUsername()) or "?" end

local function weaponClass(weapon)
    if not weapon:isRanged() then return "melee" end
    local ok, ammo = pcall(function() return tostring(weapon:getAmmoType() or ""):lower() end)
    ammo = ok and ammo or ""
    local name = tostring(weapon:getType() or ""):lower()
    if ammo:find("arrow", 1, true) or ammo:find("radarchery", 1, true) or name:find("bow", 1, true) then return "bow" end
    return "gun"
end

local function hitsToKill(kind, class, weapon)
    local range = (HITS[kind] or DEFAULT_HITS)[class]
    local span = DMG_SPAN[class]
    local t = clamp(((tonumber(weapon:getMaxDamage()) or span[1]) - span[1]) / (span[2] - span[1]), 0, 1)
    return range[2] - (range[2] - range[1]) * t
end

local function nativeMaxAndRatio(profile)
    local ns = profile.ns
    local nativeMax = VDinoDifficulty and VDinoDifficulty.nativeHealthMaximum and VDinoDifficulty.nativeHealthMaximum(ns) or 1.0
    local ratio = VDinoDifficulty and VDinoDifficulty.toughnessMultiplier and VDinoDifficulty.toughnessMultiplier(ns) or 1.0
    return nativeMax, ratio
end

local function kill(target, wielder)
    if VDinoDeath and VDinoDeath.finalize then VDinoDeath.finalize(target, wielder) else target:setHealth(0) end
end

local pendingShots = {}   -- ranged top-ups waiting for the mod's own damage to land
local lastShot = {}       -- dedupe key -> timestamp

local function onWeaponHitCharacter(wielder, target, weapon, damage)
    if not weapon or not target or not instanceof(target, "IsoAnimal") or target:isDead() or not VDinoSpecies then return false end
    local profile = VDinoSpecies.get(target)
    if not profile then return false end
    if wielder and wielder.isDoShove and wielder:isDoShove() then return false end   -- shoves stay native

    local kind = tostring(target:getAnimalType())
    local class = weaponClass(weapon)
    local nativeMax, ratio = nativeMaxAndRatio(profile)
    local before = tonumber(target:getHealth()) or 0
    local hits = hitsToKill(kind, class, weapon)
    damage = tonumber(damage) or 0

    if class == "melee" then
        local closeKill = damage >= math.max(tonumber(weapon:getMaxDamage()) or 1.0, 0.1) * DETECT_RATIO
        local share = (closeKill and CLOSE_KILL_HITS or 1) / hits
        local after = before - share * nativeMax * ratio        -- toughness divides by ratio afterwards
        if LOG_ALL_HITS or closeKill then
            log(string.format("%s %s on %s by %s (%s): %.1f hits to kill, %.0f%% of max, health %.3f -> %.3f",
                closeKill and "CLOSE KILL" or "melee", class, kind, nameOf(wielder), tostring(weapon:getFullType()),
                hits, share * 100, before, math.max(before - share * nativeMax, 0)))
        end
        if after <= 0 then kill(target, wielder)
        else
            target:setHealth(after)
            if VDinoMP and VDinoMP.syncNativeNow then VDinoMP.syncNativeNow(target) end
        end
        return true
    end

    -- guns / bows: cancel any native damage; the mod's shot code (or nothing) applies its own,
    -- then the top-up below guarantees the table share.
    local now = getTimestampMs()
    local key = tostring(target) .. "|" .. nameOf(wielder)
    if lastShot[key] and now - lastShot[key] < SHOT_DEDUPE_MS then return true end
    lastShot[key] = now
    pendingShots[#pendingShots + 1] = { target = target, wielder = wielder, before = before, at = now,
        floor = before - nativeMax / hits, kind = kind, class = class, hits = hits,
        weapon = tostring(weapon:getFullType()), who = nameOf(wielder) }
    return true
end

local function onTick()
    if #pendingShots == 0 then return end
    local now = getTimestampMs()
    local keep = {}
    for i = 1, #pendingShots do
        local s = pendingShots[i]
        if now - s.at < DELAY_MS then
            keep[#keep + 1] = s
        else
            local t = s.target
            if t and not t:isDead() then
                local cur = tonumber(t:getHealth()) or 0
                if cur > s.floor then
                    if s.floor <= 0 then kill(t, s.wielder)
                    else
                        t:setHealth(s.floor)
                        if VDinoMP and VDinoMP.syncNativeNow then VDinoMP.syncNativeNow(t) end
                    end
                end
                if LOG_ALL_HITS then
                    log(string.format("%s on %s by %s (%s): %.1f hits to kill, health %.3f -> %.3f (mod alone: %.3f)",
                        s.class, s.kind, s.who, s.weapon, s.hits, s.before, math.max(math.min(cur, s.floor), 0), cur))
                end
            elseif LOG_ALL_HITS then
                log(string.format("%s on %s by %s (%s): killed (health was %.3f)", s.class, s.kind, s.who, s.weapon, s.before))
            end
        end
    end
    pendingShots = keep
    for k, ts in pairs(lastShot) do if now - ts > 5000 then lastShot[k] = nil end end
end

-- ===== Player-side mercy (2026-09-27) ==========================================================
-- Pachy charges knock the player down on every hit, and packs chained knockdowns into a stunlock.
-- Wraps the dino mod's player damage functions (VDinoPlayerDamage, global) at server start:
--   * a knockdown only lands KNOCKDOWN_CHANCE of the time (otherwise just the push), and never
--     within KNOCKDOWN_IMMUNE_MS of the player's last knockdown;
--   * for DOWN_GRACE_MS after a knockdown, small-dino damage is x DOWN_GRACE_MULT;
--   * pack mercy: with more than PACK_FREE raptors/pachys within PACK_RADIUS tiles, each extra one
--     takes PACK_STEP off their damage (never below PACK_FLOOR).
-- Exact-damage bites (the T-Rex instakill) are never touched.
local KNOCKDOWN_CHANCE = 0.5
local KNOCKDOWN_IMMUNE_MS = 8000
local DOWN_GRACE_MS = 3000
local DOWN_GRACE_MULT = 0.5
local PACK_RADIUS = 4
local PACK_FREE = 2
local PACK_STEP = 0.15
local PACK_FLOOR = 0.55
local SMALL = { vraptor = true, vpachy = true }

local lastKnockdown = {}   -- username -> ms

local function smallDinosNear(player)
    local cell = getCell()
    local animals = cell and cell:getAnimals()
    if not animals then return 0 end
    local px, py, r2, n = player:getX(), player:getY(), PACK_RADIUS * PACK_RADIUS, 0
    for i = 0, animals:size() - 1 do
        local a = animals:get(i)
        if a and not a:isDead() and SMALL[tostring(a:getAnimalType())]
                and (a:getX() - px) ^ 2 + (a:getY() - py) ^ 2 <= r2 then n = n + 1 end
    end
    return n
end

-- Damage multiplier for a hit on this player right now (pack mercy x knockdown grace).
local function mercy(player)
    local mult = 1.0
    local n = smallDinosNear(player)
    if n > PACK_FREE then mult = math.max(PACK_FLOOR, 1.0 - PACK_STEP * (n - PACK_FREE)) end
    local down = lastKnockdown[nameOf(player)]
    if down and getTimestampMs() - down < DOWN_GRACE_MS then mult = mult * DOWN_GRACE_MULT end
    return mult, n
end

local function wrapPlayerDamage()
    local PD = VDinoPlayerDamage
    if not (PD and PD.health and PD.bite and PD.scratch) then
        log("ERROR: VDinoPlayerDamage not loaded, knockdown/pack mercy NOT active")
        return
    end
    if PD.PEWrapped then return end
    local health, bite, scratch = PD.health, PD.bite, PD.scratch

    PD.health = function(player, amount, knockdown, impact)
        if player and not player:isDead() then
            local mult = mercy(player)
            amount = (tonumber(amount) or 0) * mult
            if knockdown then
                local name, now = nameOf(player), getTimestampMs()
                local last = lastKnockdown[name]
                if (last and now - last < KNOCKDOWN_IMMUNE_MS) or ZombRandFloat(0, 1) >= KNOCKDOWN_CHANCE then
                    knockdown = false
                    if LOG_ALL_HITS then log(string.format("knockdown skipped for %s (x%.2f dmg)", name, mult)) end
                else
                    lastKnockdown[name] = now
                    if LOG_ALL_HITS then log(string.format("knockdown on %s (x%.2f dmg)", name, mult)) end
                end
            end
        end
        return health(player, amount, knockdown, impact)
    end

    local function softened(fn)
        return function(player, options)
            options = options or {}
            if player and not player:isDead() and not tonumber(options.exactHealthDamage) then
                local mult, n = mercy(player)
                if mult < 1.0 then
                    local o = {}
                    for k, v in pairs(options) do o[k] = v end
                    o.healthMultiplier = (tonumber(o.healthMultiplier) or 1.0) * mult
                    o.woundMultiplier = (tonumber(o.woundMultiplier) or 1.0) * mult
                    options = o
                    if LOG_ALL_HITS then log(string.format("pack mercy on %s: %d small dinos, x%.2f", nameOf(player), n, mult)) end
                end
            end
            return fn(player, options)
        end
    end
    PD.bite = softened(bite)
    PD.scratch = softened(scratch)
    PD.PEWrapped = true
    log(string.format("player mercy active: knockdown %d%% + %ds immunity, %ds down-grace x%.1f, pack mercy -%d%%/dino past %d (floor x%.2f)",
        KNOCKDOWN_CHANCE * 100, KNOCKDOWN_IMMUNE_MS / 1000, DOWN_GRACE_MS / 1000, DOWN_GRACE_MULT,
        PACK_STEP * 100, PACK_FREE, PACK_FLOOR))
end

Events.OnServerStarted.Add(function()
    local ok, err = pcall(wrapPlayerDamage)
    if not ok then log("mercy wrap error: " .. tostring(err)) end
end)

if Hook and Hook.WeaponHitCharacter then
    Hook.WeaponHitCharacter.Add(onWeaponHitCharacter)
    Events.OnTick.Add(onTick)
    log("dino damage model active: raptor melee 5-7 hits, guns 1-1.5 shots, bows 2-3; close kill = "
        .. CLOSE_KILL_HITS .. " melee hits" .. (LOG_ALL_HITS and "; logging every hit (temporary)" or ""))
else
    log("ERROR: Hook.WeaponHitCharacter not available, damage model NOT active")
end
