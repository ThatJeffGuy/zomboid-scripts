-- PE_SafePath.lua  (server-side only)
-- 2026-09-29 (same day): the user didn't like the gravel. PATH_ENABLED=false: no new path is laid, and
-- every tile already laid (rings and samples) gets its old ground back once its square is loaded. The
-- lines are now continuous sandbag rings (PE_DefenseLine ring walls). The warning, the HUD data and the
-- status-page export below still run.
-- Shows players where the shrinking safe zone ends (the user's design, 2026-09-29):
--   * A gravel path, one tile wide, runs round every camp on the STANDING defense line (PE_DefenseLine:
--     the outermost 50-tile ring still inside the safe radius), through the line's sandbag posts.
--   * When the line falls, its path turns scorched (burnt floor) for the ruin window, then the original
--     ground comes back. A stretch nobody saw while the line stood still shows scorched ground if a
--     player comes by during the ruin window, like the posts' ruins.
--   * WARN_HOURS before a line falls, a chat warning goes out (once per line).
--   * The global ModData "PESafeZone" (radius, standing line, when it falls, camp centers) goes to every
--     client for the map mod's on-screen banner (ZEM_SafeZone.lua), and the same data is written to
--     Lua/PE/safezone.json every minute for the status page's live map.
-- Everything is laid lazily near players, like the posts. Only natural ground gets path (never roads,
-- buildings, water, or squares with anything built on them); the floor sprite is swapped and the old one
-- is kept in ModData so it can be put back.
-- Admin (cmd.txt): "path <user>" lays a 9-tile sample east of the player, "pathburn" scorches the
-- samples, "pathclear" restores them. Log prefix "[PE-Path]".
if isClient() then return end

local KEY = "PESafePath"
local HUD_KEY = "PESafeZone"
local TICK_SECONDS = 5
local NEAR = 80                        -- path within this of a player is laid / scorched / restored
local MAX_TILES_PER_TICK = 200
local WARN_HOURS = 6
local EXPORT_SECONDS = 60
local GRAVEL = { "floors_exterior_natural_01_8", "floors_exterior_natural_01_9", "floors_exterior_natural_01_10",
    "floors_exterior_natural_01_11", "floors_exterior_natural_01_12", "floors_exterior_natural_01_13",
    "floors_exterior_natural_01_14" }
local BURNT = { "floors_burnt_01_8", "floors_burnt_01_13", "floors_burnt_01_14", "floors_burnt_01_15" }
local NATURAL = { "e_", "vegetation_", "blends_natural", "f_", "d_" }
local PATH_ENABLED = false

-- What's happening at each line (the user, 2026-09-29: a different story every time a line goes).
-- warn: the banner / status page / 6h chat warning while that line stands ({timer} = time left);
-- fallen: the chat line when it goes (PE_DefenseLine reads PELineTexts). 150 never falls.
PELineTexts = {
    [950] = { warn = "The Front Lines are not holding! Retreat in {timer}",
              fallen = "The Front Lines have fallen. Survivors are digging in at the 900 line." },
    [900] = { warn = "Raptor packs are probing the wire. Fall back in {timer}",
              fallen = "The raptors found a gap. The 900 line is lost - everyone back to 850." },
    [850] = { warn = "The outer posts have gone quiet. Pull back in {timer}",
              fallen = "Nobody answered from the 850 posts. The line is now 800." },
    [800] = { warn = "Something big is leaning on the sandbags. Retreat in {timer}",
              fallen = "Whatever it was walked straight through. Fall back to the 750 line." },
    [750] = { warn = "Ammo is running dry on the line. Fall back in {timer}",
              fallen = "The guns on the 750 line went silent. Hold at 700." },
    [700] = { warn = "The lamps are flickering out one by one. Retreat in {timer}",
              fallen = "The last lamp on the 700 line went dark. The line is now 650." },
    [650] = { warn = "The ground is shaking out past the wire. Pull back in {timer}",
              fallen = "The herd came through at 650. Regroup at the 600 line." },
    [600] = { warn = "We've lost contact with the far posts. Retreat in {timer}",
              fallen = "Radio silence from the 600 line. It's gone - fall back to 550." },
    [550] = { warn = "The herds are pushing through the gaps. Fall back in {timer}",
              fallen = "The 550 line got trampled flat. Dig in at 500." },
    [500] = { warn = "Half the line is gone. Retreat in {timer}",
              fallen = "The 500 line is rubble. The camps are pulling everyone back to 450." },
    [450] = { warn = "The wire is down in three places. Pull back in {timer}",
              fallen = "Too many holes to plug at 450. New line at 400." },
    [400] = { warn = "They've learned where the gaps are. Retreat in {timer}",
              fallen = "They walked right through the gaps at 400. Hold the 350 line." },
    [350] = { warn = "The Front Lines are breaking! Fall back in {timer}",
              fallen = "The 350 line broke. Everyone back to 300 - move!" },
    [300] = { warn = "Nobody is coming back from the outer posts. Retreat in {timer}",
              fallen = "The 300 line is lost with everyone on it. Fall back to 250." },
    [250] = { warn = "This is the last stretch of open ground. Pull back in {timer}",
              fallen = "The open ground belongs to them now. Last line before the camps: 200." },
    [200] = { warn = "Last line before the camps. Hold... retreat in {timer}",
              fallen = "The 200 line has fallen. The camps are all that's left - the 150 line holds or nothing does." },
    [150] = { warn = "The camps hold. There's nowhere left to run." },
}

local function log(msg) print("[PE-Path] " .. msg) end
local function say(msg) print("[PE-Say] " .. msg) end
local function heat() return PEDinoHeat end
local function line() return PEDefenseLine end
local function nowSec() return math.floor(getTimestampMs() / 1000) end

local function data()
    local md = ModData.getOrCreate(KEY)
    if type(md.rings) ~= "table" then md.rings = {} end
    if type(md.warned) ~= "table" then md.warned = {} end
    if type(md.samples) ~= "table" then md.samples = {} end
    return md
end

local function pick(list, x, y) return list[(x * 7 + y * 13) % #list + 1] end

local function isNatural(o)
    if instanceof(o, "IsoTree") then return false end        -- trees stay; the path goes round them
    local spr = o:getSprite()
    local name = spr and spr:getName() or ""
    for _, pre in ipairs(NATURAL) do
        if name:sub(1, #pre) == pre then return true end
    end
    return false
end

-- Natural outdoor ground with nothing built on it; returns the square's floor.
local function pathFloor(sq)
    if not sq or sq:getRoom() then return nil end
    local props = sq:getProperties()
    if props and props:has(IsoFlagType.water) then return nil end
    local floor = sq:getFloor()
    local fs = floor and floor:getSprite()
    local fname = fs and fs:getName() or ""
    if fname == "" or fname:find("street") then return nil end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if o ~= floor and not isNatural(o) then return nil end
    end
    return floor
end

local function setFloor(sq, floor, name)
    local ok = pcall(function()
        -- plants and grass tufts on top would hide the path
        local objs = sq:getObjects()
        for i = objs:size() - 1, 0, -1 do
            local o = objs:get(i)
            if o ~= floor and isNatural(o) then
                local okR = pcall(function() sq:transmitRemoveItemFromSquare(o) end)
                if not okR then pcall(function() sq:RemoveTileObject(o) end) end
            end
        end
        pcall(function() floor:clearAttachedAnimSprite() end)
        floor:setSpriteFromName(name)
        floor:transmitUpdatedSpriteToClients()
    end)
    return ok
end

local function floorName(sq)
    local f = sq and sq:getFloor()
    local s = f and f:getSprite()
    return f, s and s:getName() or nil
end

-- One tile of a ring: lay gravel ("g"), scorch ("b"), or put the old ground back ("gone").
-- Returns true if it changed something.
local function workTile(tiles, x, y, want)
    local key = x .. "," .. y
    local rec = tiles[key]
    local sq = getCell():getGridSquare(x, y, 0)
    if not sq then return false end
    if want == "gone" then
        if not rec then return false end
        local f = sq:getFloor()
        if f and rec.o then setFloor(sq, f, rec.o) end
        tiles[key] = nil
        return true
    end
    if rec and rec.s == want then return false end
    local f, cur
    if rec then
        f, cur = floorName(sq)
        if not f then return false end
    else
        f = pathFloor(sq)
        if not f then return false end
        cur = f:getSprite():getName()
    end
    local name = want == "g" and pick(GRAVEL, x, y) or pick(BURNT, x, y)
    if setFloor(sq, f, name) then
        tiles[key] = { o = rec and rec.o or cur, s = want }
        return true
    end
    return false
end

-- Squares of the circle of radius R round (cx, cy) near (px, py): a 4-connected run, so the path has
-- no diagonal gaps.
local function arcSquares(cx, cy, R, px, py)
    local out, seen = {}, {}
    local phi = math.atan2(py - cy, px - cx)
    local span = math.min(math.pi, NEAR / R + 0.05)
    local step = 0.5 / R
    local lx, ly
    local function add(x, y)
        local k = x .. "," .. y
        if not seen[k] and (x - px) ^ 2 + (y - py) ^ 2 <= NEAR * NEAR then
            seen[k] = true
            out[#out + 1] = { x, y }
        end
    end
    local a = phi - span
    while a <= phi + span do
        local x, y = math.floor(cx + R * math.cos(a)), math.floor(cy + R * math.sin(a))
        if lx and x ~= lx and y ~= ly then add(x, ly) end          -- fill the corner of a diagonal step
        add(x, y)
        lx, ly = x, y
        a = a + step
    end
    return out
end

local function ringRec(md, zi, R)
    local k = zi .. ":" .. R
    md.rings[k] = md.rings[k] or { zi = zi, R = R, tiles = {} }
    return md.rings[k]
end

-- The chat warning before the standing line falls, and the HUD/status-page data.
local lastExport = 0
local function shareState(md, radius, days)
    local h, DL = heat(), line()
    local active = DL.activeRing(radius)
    local fallsAt = nil
    if active > 150 then
        fallsAt = nowSec() + math.floor((DL.collapseDay(active) - days) * 86400)
        local hoursLeft = (DL.collapseDay(active) - days) * 24
        if hoursLeft <= WARN_HOURS and hoursLeft > 0 and not md.warned[tostring(active)] then
            md.warned[tostring(active)] = true
            local t = PELineTexts[active]
            local left = "about " .. math.max(1, math.floor(hoursLeft + 0.5)) .. " hours"
            say(t and t.warn and (t.warn:gsub("{timer}", left)) or ("The Front Lines are not holding! Retreat in " .. left))
            log(string.format("warned: line %d falls in %.1f h", active, hoursLeft))
        end
    end
    local now = nowSec()
    if now - lastExport < EXPORT_SECONDS then return end
    lastExport = now
    local hud = ModData.getOrCreate(HUD_KEY)
    hud.radius = math.floor(radius)
    hud.line = active
    hud.nextLine = active > 150 and active - 50 or nil
    hud.fallsAt = fallsAt
    hud.msg = PELineTexts[active] and PELineTexts[active].warn or "The Front Lines are not holding! Retreat in {timer}"
    hud.updated = now
    hud.camps = {}
    for i, zc in ipairs(h.ZONES) do
        hud.camps[i] = { name = h.CAMP_NAMES and h.CAMP_NAMES[i] or ("Camp " .. i), x = zc[1], y = zc[2] }
    end
    pcall(function() ModData.transmit(HUD_KEY) end)
    -- the status page reads this (JSON by hand: Kahlua has no encoder)
    local camps = {}
    for _, c in ipairs(hud.camps) do
        camps[#camps + 1] = string.format('{"name":"%s","x":%d,"y":%d}', c.name, c.x, c.y)
    end
    local msg = hud.msg:gsub('\\', ''):gsub('"', "'")
    local json = string.format('{"updated":%d,"radius":%d,"line":%d,"next_line":%s,"falls_at":%s,"msg":"%s","camps":[%s]}',
        now, hud.radius, active, hud.nextLine and tostring(hud.nextLine) or "null",
        fallsAt and tostring(fallsAt) or "null", msg, table.concat(camps, ","))
    local ok = pcall(function()
        local w = getFileWriter("PE/safezone.json", true, false)
        w:write(json)
        w:close()
    end)
    if not ok then log("could not write PE/safezone.json") end
end

local lastTick = 0
local function tick()
    local h, DL = heat(), line()
    if not (h and h.safeRadius and h.ZONES and DL and DL.ringState and DL.activeRing) then return end
    local md = data()
    local radius, days = h.safeRadius(), h.serverDays()
    shareState(md, radius, days)
    local players = getOnlinePlayers()
    if not players or players:size() == 0 then return end
    local work = 0
    if not PATH_ENABLED then
        -- put the ground back wherever gravel or scorch was laid
        local lists = { md.samples }
        for _, rec in pairs(md.rings) do lists[#lists + 1] = rec.tiles end
        for _, tiles in ipairs(lists) do
            local keys = {}
            for k in pairs(tiles) do keys[#keys + 1] = k end
            for _, k in ipairs(keys) do
                local x, y = k:match("^(-?%d+),(-?%d+)$")
                if workTile(tiles, tonumber(x), tonumber(y), "gone") then
                    work = work + 1
                    if work >= MAX_TILES_PER_TICK then return end
                end
            end
        end
        if work > 0 then log("restored " .. work .. " path tile(s) to their old ground") end
        return
    end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and not p:isDead() then
            local px, py = math.floor(p:getX()), math.floor(p:getY())
            for zi, zc in ipairs(h.ZONES) do
                local D = math.sqrt((px - zc[1]) ^ 2 + (py - zc[2]) ^ 2)
                for R = 950, 150, -50 do
                    if math.abs(D - R) <= NEAR then
                        local st = DL.ringState(R, radius, days)
                        local want = st == "active" and "g" or st == "ruin" and "b" or st == "gone" and "gone" or nil
                        local rec = want and ringRec(md, zi, R)
                        if want then
                            for _, s in ipairs(arcSquares(zc[1], zc[2], R, px, py)) do
                                if workTile(rec.tiles, s[1], s[2], want) then
                                    work = work + 1
                                    if work >= MAX_TILES_PER_TICK then return end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

Events.OnTick.Add(function()
    local now = getTimestampMs()
    if now - lastTick < TICK_SECONDS * 1000 then return end
    lastTick = now
    local ok, err = pcall(tick)
    if not ok then log("error: " .. tostring(err)) end
end)

Events.OnServerStarted.Add(function()
    log(string.format("active: path %s; line warning %dh ahead; HUD + status data", PATH_ENABLED and "on" or "OFF (restoring old tiles)", WARN_HOURS))
end)

if PEAdminCommands then
    local function adminLog(msg) print("[PE-Admin] " .. msg) end
    local function findPlayer(name)
        local players = getOnlinePlayers()
        for i = 0, players and players:size() - 1 or -1 do
            local p = players:get(i)
            if p and p:getUsername():lower() == tostring(name):lower() then return p end
        end
        return nil
    end
    PEAdminCommands.path = function(args)
        local p = findPlayer(args[1] or "")
        if not p then return adminLog("player not online: " .. tostring(args[1])) end
        local md = data()
        local x0, y0 = math.floor(p:getX()) + 3, math.floor(p:getY())
        local n = 0
        for dx = 0, 8 do
            if workTile(md.samples, x0 + dx, y0, "g") then n = n + 1 end
        end
        adminLog(string.format("path: %d sample gravel tile(s) east of %s at %d,%d", n, p:getUsername(), x0, y0))
    end
    PEAdminCommands.pathburn = function()
        local md = data()
        local n = 0
        local keys = {}
        for k in pairs(md.samples) do keys[#keys + 1] = k end
        for _, k in ipairs(keys) do
            local x, y = k:match("^(-?%d+),(-?%d+)$")
            if workTile(md.samples, tonumber(x), tonumber(y), "b") then n = n + 1 end
        end
        adminLog("pathburn: " .. n .. " sample tile(s) scorched")
    end
    PEAdminCommands.pathclear = function()
        local md = data()
        local n = 0
        local keys = {}
        for k in pairs(md.samples) do keys[#keys + 1] = k end
        for _, k in ipairs(keys) do
            local x, y = k:match("^(-?%d+),(-?%d+)$")
            if workTile(md.samples, tonumber(x), tonumber(y), "gone") then n = n + 1 end
        end
        adminLog("pathclear: " .. n .. " sample tile(s) restored")
    end
end
