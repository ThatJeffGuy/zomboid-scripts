-- Project Evolution dinosaur damage model (server-side only, outside the Lua checksum).
-- Replaces PE_CloseKillGuard.lua (2026-09-26). Theme: dinosaurs are used to claws and teeth but
-- have never seen guns, so melee is a slog (raptor 7-10 hits) and guns are powerful (1-2 shots).
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
    vraptor = { melee = { 7, 10 },  gun = { 1, 2 }, bow = { 3, 4 } },
    vpachy  = { melee = { 7, 10 },  gun = { 1, 2 }, bow = { 3, 5 } },
    vcarno  = { melee = { 10, 14 }, gun = { 2, 3 }, bow = { 5, 7 } },
    vstego  = { melee = { 14, 18 }, gun = { 3, 4 }, bow = { 7, 9 } },
    vanky   = { melee = { 16, 20 }, gun = { 3, 5 }, bow = { 8, 10 } },
    vtrex   = { melee = { 25, 30 }, gun = { 5, 8 }, bow = { 12, 15 } },
}
local DEFAULT_HITS = { melee = { 10, 14 }, gun = { 2, 3 }, bow = { 5, 7 } }
-- weapon MaxDamage that maps to the weak / strong end of each range
local DMG_SPAN = { melee = { 0.6, 3.0 }, gun = { 1.0, 2.2 }, bow = { 0.5, 1.4 } }
local CLOSE_KILL_HITS = 2          -- a chin stab is worth this many melee hits
local DETECT_RATIO = 100           -- melee hit >= this x weapon max damage = close kill (x1000)
local DELAY_MS = 350               -- ranged top-up runs after the mod's shot + toughness settle
local SHOT_DEDUPE_MS = 250         -- one ranged hit per shooter+target per window (pellets, echoes)

local LOG_ALL_HITS = true          -- TEMPORARY: log every hit on a dino while tuning

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

if Hook and Hook.WeaponHitCharacter then
    Hook.WeaponHitCharacter.Add(onWeaponHitCharacter)
    Events.OnTick.Add(onTick)
    log("dino damage model active: raptor melee 7-10 hits, guns 1-2 shots, bows 3-4; close kill = "
        .. CLOSE_KILL_HITS .. " melee hits" .. (LOG_ALL_HITS and "; logging every hit (temporary)" or ""))
else
    log("ERROR: Hook.WeaponHitCharacter not available, damage model NOT active")
end
