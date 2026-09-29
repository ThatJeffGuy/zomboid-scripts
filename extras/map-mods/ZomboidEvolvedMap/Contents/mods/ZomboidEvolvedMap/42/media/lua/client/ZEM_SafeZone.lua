-- ZEM_SafeZone.lua  (client)
-- The camps' shrinking safe zones get the same slide-in banner as the Aegis rule zones (the user's ask,
-- 2026-09-29): hop the sandbag ring on the standing defense line and "Amber Safe Zone" slides in,
-- leave and "Left ..." slides in. The server keeps the numbers in the global ModData "PESafeZone"
-- (line = the standing ring's radius, fallsAt, camps; see PE_SafePath.lua on the server).
-- How: Aegis's client (AegisRuleZonesClient) asks zoneAt(x, y) twice a second and shows its banner when
-- the answer changes. This wraps zoneAt: an Aegis zone still wins (the camp itself keeps its own banner),
-- otherwise inside a ring the answer is a made-up zone for that camp, and its banner lines come from a
-- wrapped ruleLabels. Nothing here enforces anything; it only draws (the rules are enforced by
-- PE_SafeRules.lua on the server, which sends "ZEM denied" to show here).
-- Needs the Aegis mod (AP). Switch off in Options > Mods > Zomboid Evolved Core.
if isServer() then return end
require "ZEM_WorldMap"

local KEY = "PESafeZone"
local ZEM = ZomboidEvolvedMap
local option = ZEM and ZEM.options and ZEM.options:addTickBox("safeZoneHud", "Safe zone banner", true,
    "Slides in a banner when you cross into or out of a camp's safe zone (the sandbag ring).")

local zone = nil                       -- the server's PESafeZone data
local fake = {}                        -- camp index -> the made-up Aegis zone for it
local ticks = 0

local function receive(key, data)
    if key ~= KEY or type(data) ~= "table" then return end
    zone = data
end

local function countdown(seconds)
    if seconds <= 0 then return "any moment" end
    local d = math.floor(seconds / 86400)
    local h = math.floor(seconds % 86400 / 3600)
    local m = math.floor(seconds % 3600 / 60)
    if d > 0 then return string.format("%dd %dh", d, h) end
    if h > 0 then return string.format("%dh %dm", h, m) end
    return string.format("%dm", m)
end

-- The camp whose standing ring (x, y) is inside, or nil. A little slack on the way out (EXIT_SLACK
-- tiles past the ring) so hopping the sandbags or walking along the ring doesn't flicker the banner
-- in and out (the user saw it twice running straight across).
local EXIT_SLACK = 4
local insideCamp = nil
local function campAt(x, y)
    if not zone or type(zone.camps) ~= "table" then return nil end
    if option and option:getValue() == false then return nil end
    local R = tonumber(zone.line)
    if not R then return nil end
    -- the slack only applies to the local player's own square (Aegis also asks about zombies' squares)
    local p = getPlayer()
    local self = p and math.floor(p:getX()) == x and math.floor(p:getY()) == y
    for i, c in ipairs(zone.camps) do
        local r = (self and i == insideCamp) and (R + EXIT_SLACK) or R
        if (x + 0.5 - c.x) ^ 2 + (y + 0.5 - c.y) ^ 2 < r * r then
            if self then insideCamp = i end
            return i, c
        end
    end
    if self then insideCamp = nil end
    return nil
end

local function fakeZone(i, c)
    local z = fake[i]
    if not z then
        -- colour 1 is Aegis's red; every rule flag off, so Aegis enforces nothing here
        -- "Driftwood Safe Zone", never "Camp ...": the camp itself (its Aegis zone) is "Camp Driftwood",
        -- and the two read as one place when both start with the camp (the user, 2026-09-29)
        local short = tostring(c.name):gsub("^Camp%s+", "")
        z = { id = "zesafe" .. i, name = short .. " Safe Zone", color = 1, zeSafe = true,
              pvp = 0, zombies = 0, npcs = 0, build = 0, fire = 0, alarm = 0, power = 0, water = 0, rects = {} }
        fake[i] = z
    end
    return z
end

local function wrap()
    local A = AegisRuleZonesClient
    if not A or A.zeSafeWrapped then return A ~= nil end
    local zoneAt, ruleLabels = A.zoneAt, A.ruleLabels
    -- One banner per safe zone (the user, 2026-09-29: the camp's own banner inside the safe zone read as
    -- a second zone, and walking out of the camp showed the safe zone banner again). Inside a ring the
    -- answer is always that camp's safe zone, same id throughout, so Aegis sees no change at the camp
    -- edge. Inside the camp itself it carries the camp zone's rule flags, so Aegis's client-side
    -- zombie/NPC wall at the camp keeps working (the server enforces the camp rules on its own).
    local merged = {}
    A.zoneAt = function(x, y)
        local z = zoneAt(x, y)
        local i, c = campAt(x, y)
        if not i then return z end
        local f = fakeZone(i, c)
        if not z then return f end
        local m = merged[i]
        if not m or m.src ~= z then
            m = { id = f.id, name = f.name, color = f.color, zeSafe = true, src = z, rects = z.rects,
                  pvp = z.pvp, zombies = z.zombies, npcs = z.npcs, build = z.build, fire = z.fire,
                  alarm = z.alarm, power = z.power, water = z.water }
            merged[i] = m
        end
        return m
    end
    A.ruleLabels = function(z)
        if not (z and z.zeSafe) then return ruleLabels(z) end
        local out = { "No building", "No destroying", "Fire doesn't spread" }
        local fallsAt = tonumber(zone and zone.fallsAt)
        -- the server picks a different line of story for every line (PELineTexts in PE_SafePath.lua)
        local msg = type(zone and zone.msg) == "string" and zone.msg or "The Front Lines are not holding! Retreat in {timer}"
        if fallsAt and zone.line then
            local timer = countdown(fallsAt - math.floor(getTimestampMs() / 1000))
            out[#out + 1] = (msg:gsub("{timer}", timer))
        else
            out[#out + 1] = (msg:gsub("{timer}", ""))
        end
        return out
    end
    A.zeSafeWrapped = true
    return true
end

-- The server refused an action inside a safe zone (PE_SafeRules.lua): say so.
local DENIED = {
    building = "No building inside the safe zone",
    barricading = "No barricading inside the safe zone",
    destroying = "No destroying inside the safe zone",
    dismantling = "No dismantling inside the safe zone",
}
Events.OnServerCommand.Add(function(module, command, args)
    if module ~= "ZEM" or command ~= "denied" or type(args) ~= "table" then return end
    local msg = DENIED[args.what] or ("Not allowed inside the safe zone: " .. tostring(args.what))
    local shown = Aegis and Aegis.showToast and pcall(function() Aegis.showToast(msg) end)
    if not shown then
        local p = getPlayer()
        if p then pcall(function() HaloTextHelper.addBadText(p, msg) end) end
    end
end)

Events.OnReceiveGlobalModData.Add(receive)
Events.OnInitGlobalModData.Add(function()
    if not isClient() then return end
    pcall(function() ModData.request(KEY) end)
end)
Events.OnGameStart.Add(function()
    local ok, err = pcall(wrap)
    if not ok then print("[ZEM-SafeZone] " .. tostring(err)) end
end)
Events.OnTick.Add(function()
    if not isClient() then return end
    ticks = ticks + 1
    if ticks < 300 then return end                    -- about every 5 seconds
    ticks = 0
    if not (AegisRuleZonesClient and AegisRuleZonesClient.zeSafeWrapped) then pcall(wrap) end
    if not zone then pcall(function() ModData.request(KEY) end) end
end)
