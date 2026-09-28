-- PE_DefenseLine.lua  (server-side only, outside the Lua checksum)
-- Collapsing defense lines (the user's option C, 2026-09-28): rings of small sandbag posts around each
-- camp that fall back as the safe radius shrinks (PE_DinoHeat: 1000 tiles on day 0 -> 150 by day 30).
--   * Lines stand every RING_STEP tiles of radius (950, 900, ... 150). The ACTIVE line is the outermost
--     ring still inside the safe radius. Every ~POST_SPACING tiles around it stands a single-row gate: a
--     short row of sandbags along the ring with one lamp post behind it (the user's design, 2026-09-28).
--   * When the safe radius drops below a ring, that line has collapsed: its posts become ruins (some
--     sandbags gone, a charred stump, debris) with a lootable crate. A slot nobody saw while it stood
--     still shows ruins if a player comes by during the ruin window: something stood there.
--   * RUIN_DAYS after the collapse the ruins are cleared away. The 150 line is the last and never falls.
--   * Wherever a road crosses the line there is a CHECKPOINT instead (the user's design, 2026-09-28): two
--     sandbag walls across the road, front and back, and a sandbag nest on each shoulder with a lamp.
--     PE_Sentries builds the same checkpoint over the roads into each camp (checkpointParts below).
--   * Every lamp is secretly a gun (PE_Sentries: dinos and hostile bandits near a lit lamp are shot).
--   * Lamps are decorative lamp-pillar tiles; their light is drawn by every client (ZEM_Lights.lua in the
--     ZomboidEvolvedMap mod) from the global ModData "PELights" kept here, so it never goes out and
--     there is nothing to loot. A ruin's lamps are gone (the light goes out with the line).
--   * Everything is built lazily, only where a player is near and every square is loaded; changes are
--     transmitted to clients (same placement approach as PE_Sentries / PE_Outposts).
--   * Ruin loot follows the same rules as all other Evolved loot: a curated table (no guns, no
--     batteries), every entry checked against the live LootItemRemovalList, missing items skipped.
-- Admin commands (PE_AdminCmd cmd.txt): "lines" (status), "line <user> [gate|ruin|checkpoint]" (sample
-- next to a player, for a look), "lineclear" (remove the samples).
-- Log prefix "[PE-Line]"; chat via "[PE-Say]". Edit the canonical copy in config/presets/.
if isClient() then return end

local KEY = "PEDefenseLine"
local TICK_SECONDS = 5
local RING_STEP = 50                  -- tiles of radius between lines
local RING_OUTER, RING_INNER = 950, 150
local POST_SPACING = 40               -- tiles between posts along a ring
local NEAR = 90                       -- a slot within this of a player is built / converted / cleared
local SEARCH = 8                      -- tiles searched around a slot's ideal spot for a usable footprint
local RUIN_DAYS = 3                   -- server days ruins stay after their line collapses
local MAX_WORK_PER_TICK = 2           -- slots built/converted/cleared per tick
local SANDBAG_KEEP = 0.4              -- share of sandbags still standing in a ruin
local RUIN_ROLLS_MIN, RUIN_ROLLS_MAX = 3, 6

local SANDBAG_N, SANDBAG_W = "carpentry_02_13", "carpentry_02_12"   -- entity SandbagWall faces N / W
local SEG_LEN = 5                     -- sandbags in a single-row gate
local LAMP = "carpentry_02_59"        -- wooden lamp pillar (entity WoodLampPillar, face S); decoration only
local CHECK_MAX_ROAD = 8              -- widest road that gets a checkpoint (same cap as the camp gates)
local CHECK_SPACING = 12              -- two checkpoints on one ring are at least this far apart
local REPAIR_SECONDS = 300            -- standing posts/checkpoints near a player get missing pieces back
local LIGHTS_KEY = "PELights"
local LIGHTS_RESEND = 60              -- seconds; clients also get every change right away
local STUMP = "walls_burnt_01_2"      -- charred NW corner wall
local CRATE = "furniture_storage_02_29"
local DEBRIS = { "damaged_objects_01_12", "damaged_objects_01_13", "damaged_objects_01_14",
                 "d_trash_1_0", "d_trash_1_1", "d_trash_1_2", "d_trash_1_3", "d_trash_1_4", "d_trash_1_5" }

-- Abandoned-post supplies. No guns (the only guns on Evolved are crafted black powder guns).
local LOOT = {
    { "Base.TinnedBeans", 5 }, { "Base.CannedChili", 4 }, { "Base.BeefJerky", 5 }, { "Base.DehydratedMeatStick", 4 },
    { "Base.WaterBottle", 4 }, { "bdtmre.bdtmre26a1", 1 }, { "bdtmre.bdtmre93c5", 1 },
    { "Base.Bandage", 5 }, { "Base.AlcoholBandage", 3 }, { "Base.Disinfectant", 2 }, { "Base.Pills", 2 },
    { "Base.EmptySandbag", 6 }, { "Base.Nails", 4 }, { "Base.Rope", 3 }, { "Base.Twine", 3 }, { "Base.Tarp", 2 },
    { "Base.Hammer", 1 }, { "Base.Shovel", 1 }, { "Base.Matches", 4 }, { "Base.Candle", 2 }, { "Base.TorchCloth", 2 },
    { "Base.Lantern_Hurricane", 1 }, { "Base.LeatherStrips", 3 },
    { "Base.StoneTippedArrow", 3 }, { "Base.CarvedArrow", 3 }, { "Base.BoneTippedArrow", 2 },
    { "Gunsmithing.MusketBall", 2 }, { "Gunsmithing.PaperCartridge_Ball", 2 }, { "Gunsmithing.CapsPackage", 1 },
    { "Gunsmithing.FlintFlake", 2 }, { "Base.GunPowder", 1 },
}

local function log(msg) print("[PE-Line] " .. msg) end
local function say(msg) print("[PE-Say] " .. msg) end
local function heat() return PEDinoHeat end   -- PE_DinoHeat loads after this file; read it lazily

local function data()
    local md = ModData.getOrCreate(KEY)
    if type(md.slots) ~= "table" then md.slots = {} end
    if type(md.fallen) ~= "table" then md.fallen = {} end
    if type(md.samples) ~= "table" then md.samples = {} end
    if type(md.checkpoints) ~= "table" then md.checkpoints = {} end
    return md
end

-- Lights -------------------------------------------------------------------------------------------------
-- Global ModData PELights.lamps = { ["x,y,z"] = true }, transmitted to every client (ZEM_Lights.lua draws
-- the light). Sent on every change and re-sent every LIGHTS_RESEND seconds for anyone who just joined.
local lightsDirty, lastLightsSend = true, 0
local function lights()
    local ld = ModData.getOrCreate(LIGHTS_KEY)
    if type(ld.lamps) ~= "table" then ld.lamps = {} end
    return ld
end

local function setLight(x, y, z, on)
    local key = x .. "," .. y .. "," .. z
    local ld = lights()
    if (ld.lamps[key] == true) ~= (on == true) then
        ld.lamps[key] = on and true or nil
        lightsDirty = true
    end
end

local function sendLights(nowMs)
    if lightsDirty or nowMs - lastLightsSend >= LIGHTS_RESEND * 1000 then
        lights()
        pcall(function() ModData.transmit(LIGHTS_KEY) end)
        lightsDirty, lastLightsSend = false, nowMs
    end
end

-- Rings and their timing ---------------------------------------------------------------------------
-- The server day on which the safe radius drops below R (PE_DinoHeat's linear ramp).
local function collapseDay(R)
    local h = heat()
    return h.RAMP_DAYS * (h.SAFE_START - R) / (h.SAFE_START - h.SAFE_END)
end

-- The standing line: the outermost ring still inside the safe radius (never inside RING_INNER).
local function activeRing(radius)
    return math.max(RING_INNER, math.min(RING_OUTER, math.floor(radius / RING_STEP) * RING_STEP))
end

-- "active" (standing), "future" (inside the active line, not built yet), "ruin" (fallen within
-- RUIN_DAYS) or "gone" (fallen longer ago).
local function ringState(R, radius, days)
    local active = activeRing(radius)
    if R == active then return "active" end
    if R < active then return "future" end
    return days < collapseDay(R) + RUIN_DAYS and "ruin" or "gone"
end

local function slotCount(R) return math.max(12, math.floor(2 * math.pi * R / POST_SPACING + 0.5)) end

-- Loot -----------------------------------------------------------------------------------------------
local removed = nil
local function isRemoved(fullType)
    if not removed then
        removed = {}
        for name in string.gmatch(SandboxVars and SandboxVars.LootItemRemovalList or "", "[^,]+") do
            name = name:match("^%s*(.-)%s*$")
            if name ~= "" then
                removed[name] = true
                removed[name:match("%.(.+)$") or name] = true
            end
        end
    end
    return removed[fullType] == true or removed[fullType:match("%.(.+)$") or fullType] == true
end

local lootList, lootTotal = nil, 0
local function rollItem()
    if not lootList then
        lootList = {}
        for _, e in ipairs(LOOT) do
            local ok, item = pcall(function() return getScriptManager():FindItem(e[1]) end)
            if not (ok and item) then log("loot item missing, skipped: " .. e[1])
            elseif isRemoved(e[1]) then log("loot item on the removal list, skipped: " .. e[1])
            else lootList[#lootList + 1] = e; lootTotal = lootTotal + e[2] end
        end
    end
    if lootTotal <= 0 then return nil end
    local r = ZombRandFloat(0, lootTotal)
    for _, e in ipairs(lootList) do
        r = r - e[2]
        if r <= 0 then return e[1] end
    end
    return lootList[#lootList][1]
end

-- Squares and objects ----------------------------------------------------------------------------------
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

-- Loaded, outdoors, dry, not a road, and holding nothing but floor and plants.
local function squareOk(sq)
    if not sq or sq:getRoom() then return false end
    local props = sq:getProperties()
    if props and props:has(IsoFlagType.water) then return false end
    if sq:getMovingObjects():size() > 0 then return false end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        local spr = o:getSprite()
        local name = spr and spr:getName() or ""
        if name:find("street") then return false end
        local p = spr and spr:getProperties()
        local isFloor = p and p:has(IsoFlagType.solidfloor)
        if not isFloor and not isNatural(o) then return false end
    end
    return true
end

-- Why squareOk refuses a square (admin diagnostics only).
local function squareReason(sq)
    if not sq then return "not loaded" end
    if sq:getRoom() then return "indoors" end
    local props = sq:getProperties()
    if props and props:has(IsoFlagType.water) then return "water" end
    if sq:getMovingObjects():size() > 0 then return "moving object" end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        local spr = o:getSprite()
        local name = spr and spr:getName() or "?"
        if name:find("street") then return "road" end
        local p = spr and spr:getProperties()
        if not (p and p:has(IsoFlagType.solidfloor)) and not isNatural(o) then return "object " .. name end
    end
    return nil
end

local function boxLoaded(x1, y1, x2, y2)
    local cell = getCell()
    return cell:getGridSquare(x1, y1, 0) ~= nil and cell:getGridSquare(x2, y1, 0) ~= nil
        and cell:getGridSquare(x1, y2, 0) ~= nil and cell:getGridSquare(x2, y2, 0) ~= nil
        and cell:getGridSquare(math.floor((x1 + x2) / 2), math.floor((y1 + y2) / 2), 0) ~= nil
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

local function placeTile(p)
    local sq = squareAt(p.x, p.y, p.z)
    if not sq then return false end
    return pcall(function()
        local obj = IsoObject.new(sq, p.s, "")
        sq:AddTileObject(obj)
        obj:transmitCompleteItemToClients()
    end)
end

local function placeCrate(p)
    local sq = squareAt(p.x, p.y, 0)
    if not sq then return 0 end
    local n = 0
    local ok = pcall(function()
        local obj = IsoThumpable.new(getCell(), sq, CRATE, false, {})
        obj:setIsContainer(true)
        sq:AddSpecialObject(obj)
        local c = obj:getContainer()
        for _ = 1, RUIN_ROLLS_MIN + ZombRand(RUIN_ROLLS_MAX - RUIN_ROLLS_MIN + 1) do
            local it = rollItem()
            if it and c:AddItem(it) then n = n + 1 end
        end
        obj:transmitCompleteItemToClients()
    end)
    return ok and n or 0
end

-- Removes the object with this part's sprite from its square (the first match); a lamp's light goes out.
local function removePart(p)
    if p.k == "lamp" then setLight(p.x, p.y, p.z, false) end
    local sq = getCell():getGridSquare(p.x, p.y, p.z)
    if not sq then return false end
    local objs = sq:getObjects()
    for i = objs:size() - 1, 0, -1 do
        local o = objs:get(i)
        local spr = o and o:getSprite()
        if spr and spr:getName() == p.s then removeObject(sq, o) return true end
    end
    return true   -- already gone (dismantled, burnt...)
end

local function hasSprite(sq, sprite)
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local s = objs:get(i):getSprite()
        if s and s:getName() == sprite then return true end
    end
    return false
end

-- Places parts (plants on their squares cleared first); with onlyMissing, just the ones that are gone.
-- Returns the parts now standing. Lamps that stand get their light.
local function placeAll(parts, onlyMissing)
    local out = {}
    for _, p in ipairs(parts) do
        local sq = getCell():getGridSquare(p.x, p.y, p.z)
        local ok
        if onlyMissing and sq and hasSprite(sq, p.s) then ok = true
        else
            if p.z == 0 then clearPlants(sq) end
            ok = placeTile(p)
        end
        if ok then
            out[#out + 1] = p
            if p.k == "lamp" then setLight(p.x, p.y, p.z, true) end
        end
    end
    return out
end

-- Layouts ------------------------------------------------------------------------------------------------
-- Single-row gate: SEG_LEN sandbags along the ring on the N (horizontal) or W (vertical) edges of the row
-- through (cx, cy), and a lamp post on the camp side of the middle bag. horizontal = the ring runs along
-- x here (a north or south stretch). campSide = +1 when the camp lies toward +y (horizontal) / +x.
-- Returns parts and the lamp square.
local function segmentParts(cx, cy, horizontal, campSide)
    local parts, half = {}, math.floor(SEG_LEN / 2)
    for i = -half, half do
        if horizontal then parts[#parts + 1] = { x = cx + i, y = cy, z = 0, s = SANDBAG_N, k = "bag" }
        else parts[#parts + 1] = { x = cx, y = cy + i, z = 0, s = SANDBAG_W, k = "bag" } end
    end
    local lx, ly = cx, cy                 -- the edge lies between cy - 1 and cy (cx - 1 and cx)
    if horizontal then ly = campSide > 0 and cy or cy - 1 else lx = campSide > 0 and cx or cx - 1 end
    parts[#parts + 1] = { x = lx, y = ly, z = 0, s = LAMP, k = "lamp" }
    return parts, lx, ly
end

-- The row's squares and the squares on both sides of its edge must be clear (and outside safehouses).
local function segmentOk(cx, cy, horizontal)
    local half = math.floor(SEG_LEN / 2)
    local x1, y1, w, h
    if horizontal then x1, y1, w, h = cx - half, cy - 1, SEG_LEN, 2 else x1, y1, w, h = cx - 1, cy - half, 2, SEG_LEN end
    local okS, sh = pcall(function() return SafeHouse.getSafeHouse(x1, y1, w, h) end)
    if okS and sh then return false end
    local cell = getCell()
    for dx = 0, w - 1 do
        for dy = 0, h - 1 do
            if not squareOk(cell:getGridSquare(x1 + dx, y1 + dy, 0)) then return false end
        end
    end
    return true
end

-- A single-row gate as near (px, py) as fits: parts, lamp x, lamp y; nil if none fits, false if not loaded.
-- zc = the camp it guards (the lamp goes on that side).
local function planSegment(px, py, horizontal, zc)
    local bx, by = math.floor(px), math.floor(py)
    if not boxLoaded(bx - SEARCH - 3, by - SEARCH - 3, bx + SEARCH + 3, by + SEARCH + 3) then return false end
    for r = 0, SEARCH do
        for dx = -r, r do
            for dy = -r, r do
                if (math.abs(dx) == r or math.abs(dy) == r) and segmentOk(bx + dx, by + dy, horizontal) then
                    local cx, cy = bx + dx, by + dy
                    local campSide
                    if horizontal then campSide = zc[2] >= cy and 1 or -1 else campSide = zc[1] >= cx and 1 or -1 end
                    return segmentParts(cx, cy, horizontal, campSide)
                end
            end
        end
    end
    return nil
end

-- The single-row gate for slot k of n on ring R.
local function ringSegment(zc, R, k, n)
    local a = 2 * math.pi * k / n
    return planSegment(zc[1] + R * math.cos(a), zc[2] + R * math.sin(a), math.abs(math.sin(a)) > math.abs(math.cos(a)), zc)
end

-- A square a checkpoint wall may stand on: loaded, outdoors, dry, and holding nothing but floor, road
-- markings and plants (so never on top of something a player placed, or on our own posts).
local function wallSquareOk(sq)
    if not sq or sq:getRoom() then return false end
    local props = sq:getProperties()
    if props and props:has(IsoFlagType.water) then return false end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        local spr = o:getSprite()
        local name = spr and spr:getName() or ""
        local p = spr and spr:getProperties()
        if not (p and p:has(IsoFlagType.solidfloor)) and not isNatural(o) and not name:find("street") then return false end
    end
    return true
end

-- Checkpoint over a road (the user's design, 2026-09-28). Coordinates are (u, v): u runs ACROSS the road
-- (the road's squares are u = a..b), v runs ALONG it. axis "x": the road runs north-south, u = x, v = y;
-- axis "y": the road runs east-west, u = y, v = x. The two walls stand on v = line and v = line + 3 (the
-- front and back), across the road and both shoulders. On each shoulder a sandbag nest (3x3, v = line ..
-- line + 2) closes the walls into a box, open toward the road, with a lamp in the middle. A shoulder that
-- isn't clear gets no nest; the walls then end one tile past the road.
-- Returns parts, center u/v (for the ruin), or nil if even the road walls can't stand.
local function checkpointParts(axis, line, a, b)
    local cell = getCell()
    local function at(u, v) if axis == "x" then return u, v end return v, u end
    local WALL = axis == "x" and SANDBAG_N or SANDBAG_W      -- runs along u, on the v edge
    local CROSS = axis == "x" and SANDBAG_W or SANDBAG_N     -- runs along v, on the u edge
    local function sqAt(u, v) local x, y = at(u, v) return cell:getGridSquare(x, y, 0) end
    local function clear(u1, u2)
        for u = u1, u2 do for v = line, line + 3 do if not squareOk(sqAt(u, v)) then return false end end end
        return true
    end
    local westNest = clear(a - 4, a - 1)
    local eastNest = clear(b + 1, b + 5)
    local u1 = westNest and a - 4 or a - 1
    local u2 = eastNest and b + 4 or b + 1
    local parts = {}
    local function add(u, v, s, k)
        local x, y = at(u, v)
        parts[#parts + 1] = { x = x, y = y, z = 0, s = s, k = k }
    end
    local walls = 0
    for u = u1, u2 do
        for _, v in ipairs({ line, line + 3 }) do
            if wallSquareOk(sqAt(u, v)) then add(u, v, WALL, "bag"); walls = walls + 1 end
        end
    end
    if walls < (b - a + 1) then return nil end               -- most of the road can't be closed off
    local lamps = {}
    local function nest(outer, inner, mid)
        for v = line, line + 2 do
            add(outer, v, CROSS, "bag")
            if v ~= line + 1 then add(inner, v, CROSS, "bag") end   -- opening toward the road
        end
        add(mid, line + 1, LAMP, "lamp")
        lamps[#lamps + 1] = mid
    end
    if westNest then nest(a - 4, a - 1, a - 3) end
    if eastNest then nest(b + 5, b + 2, b + 3) end
    -- no room for a nest: a lamp post (a gun) just inside the wall's end, if that square is clear
    if not westNest and squareOk(sqAt(a - 1, line + 1)) then add(a - 1, line + 1, LAMP, "lamp"); lamps[#lamps + 1] = a - 1 end
    if not eastNest and squareOk(sqAt(b + 1, line + 1)) then add(b + 1, line + 1, LAMP, "lamp"); lamps[#lamps + 1] = b + 1 end
    local cu = lamps[1] or math.floor((a + b) / 2)
    local cx, cy = at(cu, line + 1)
    return parts, cx, cy, u1, u2
end

-- What a ruin adds on top of the surviving sandbags, around (cx, cy): a charred stump, debris, the crate.
local function ruinExtras(cx, cy)
    local extras = { { x = cx, y = cy, z = 0, s = STUMP, k = "stump" } }
    for _ = 1, 3 + ZombRand(3) do
        extras[#extras + 1] = { x = cx - 2 + ZombRand(5), y = cy - 2 + ZombRand(5), z = 0,
                                s = DEBRIS[ZombRand(#DEBRIS) + 1], k = "debris" }
    end
    local spots = { { -1, -1 }, { 0, -1 }, { 1, -1 }, { -1, 0 }, { 1, 0 }, { -1, 1 }, { 0, 1 }, { 1, 1 } }
    local c = spots[ZombRand(#spots) + 1]
    extras[#extras + 1] = { x = cx + c[1], y = cy + c[2], z = 0, s = CRATE, k = "crate" }
    return extras
end

-- Ruins from a layout. standing = the parts are in the world (knock most of them down; lamps go dark),
-- otherwise the parts are only a plan (place the survivors). Returns the parts left and the crate's items.
local function ruinFrom(parts, cx, cy, standing)
    local out, items = {}, 0
    for _, p in ipairs(parts) do
        local keep = p.k == "bag" and ZombRandFloat(0, 1) < SANDBAG_KEEP
        if standing then
            if keep then out[#out + 1] = p else removePart(p) end
        elseif keep then
            clearPlants(getCell():getGridSquare(p.x, p.y, 0))
            if placeTile(p) then out[#out + 1] = p end
        end
    end
    for _, p in ipairs(ruinExtras(cx, cy)) do
        if p.k == "crate" then
            items = placeCrate(p)
            out[#out + 1] = p
        elseif placeTile(p) then
            out[#out + 1] = p
        end
    end
    return out, items
end

local function clearParts(parts)
    for _, p in ipairs(parts or {}) do removePart(p) end
end

-- A road crossing: the run of road squares through (x, y) across the road, and which way the road runs.
-- The road runs along whichever axis its run through (x, y) is longer. Returns axis, line, a, b or nil.
local function roadAt(x, y)
    local sq = getCell():getGridSquare(x, y, 0)
    if not sq then return false end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local spr = objs:get(i):getSprite()
        if spr and (spr:getName() or ""):find("street") then return true end
    end
    return false
end

local function runLen(x, y, dx, dy)
    local lo, hi = 0, 0
    while lo < 24 and roadAt(x - (lo + 1) * dx, y - (lo + 1) * dy) do lo = lo + 1 end
    while hi < 24 and roadAt(x + (hi + 1) * dx, y + (hi + 1) * dy) do hi = hi + 1 end
    return lo, hi
end

local function crossingAt(x, y)
    if not roadAt(x, y) then return nil end
    local wlo, whi = runLen(x, y, 1, 0)       -- along x
    local nlo, nhi = runLen(x, y, 0, 1)       -- along y
    if wlo + whi >= nlo + nhi then            -- an east-west road: the walls run along y (axis "y")
        return "y", x - 1, y - nlo, y + nhi
    end
    return "x", y - 1, x - wlo, x + whi       -- a north-south road: the walls run along x (axis "x")
end

-- Per-slot work ----------------------------------------------------------------------------------------
-- A slot is one single-row gate. state: nil (never touched), "post" (standing), "ruin", "gone", "none"
-- (nothing fits near the slot). x, y = the lamp square (the gate's middle).
local function workSlot(md, zi, zc, R, k, n, rstate)
    local key = zi .. ":" .. R .. ":" .. k
    local slot = md.slots[key]
    local st = slot and slot.state
    if rstate == "active" then
        if st then return false end
        local plan, lx, ly = ringSegment(zc, R, k, n)
        if plan == false then return false end                -- not loaded yet
        if not plan then md.slots[key] = { state = "none" } return true end
        local parts = placeAll(plan)
        md.slots[key] = { state = "post", x = lx, y = ly, parts = parts }
        log(string.format("gate %s built at %d,%d (%d pieces)", key, lx, ly, #parts))
        return true
    elseif rstate == "ruin" then
        if st == "ruin" or st == "gone" or st == "none" then return false end
        local out, items, lx, ly
        if st == "post" then
            lx, ly = slot.x, slot.y
            if not boxLoaded(lx - 8, ly - 8, lx + 8, ly + 8) then return false end
            out, items = ruinFrom(slot.parts, lx, ly, true)
        else
            local plan
            plan, lx, ly = ringSegment(zc, R, k, n)
            if plan == false then return false end
            if not plan then md.slots[key] = { state = "none" } return true end
            out, items = ruinFrom(plan, lx, ly, false)
        end
        md.slots[key] = { state = "ruin", x = lx, y = ly, parts = out }
        log(string.format("gate %s is now a ruin at %d,%d (crate with %d items)", key, lx, ly, items))
        return true
    elseif rstate == "gone" then
        if st ~= "post" and st ~= "ruin" then return false end
        if not boxLoaded(slot.x - 8, slot.y - 8, slot.x + 8, slot.y + 8) then return false end
        clearParts(slot.parts)
        md.slots[key] = { state = "gone" }
        log(string.format("gate %s ruins cleared at %d,%d", key, slot.x, slot.y))
        return true
    end
    return false
end

-- Checkpoints on the rings ----------------------------------------------------------------------------------
-- Road crossings of ring R near (px, py): the ring is sampled about a tile apart; a run of road samples is
-- one crossing, keyed by the sample its run starts at (so the key doesn't depend on whose window found it).
local function ringCrossings(zc, R, px, py)
    local n = math.max(64, math.floor(2 * math.pi * R + 0.5))
    local function pos(k)
        local a = 2 * math.pi * k / n
        return math.floor(zc[1] + R * math.cos(a) + 0.5), math.floor(zc[2] + R * math.sin(a) + 0.5)
    end
    local function road(k) local x, y = pos(k) return roadAt(x, y) end
    local k0 = math.floor(math.atan2(py - zc[2], px - zc[1]) / (2 * math.pi) * n + 0.5)
    local out, k = {}, k0 - NEAR
    while road(k) and k > k0 - NEAR - 40 do k = k - 1 end        -- a run on the window's edge: find its start
    while k <= k0 + NEAR do
        if road(k) then
            local ks = k
            while road(k + 1) and k - ks < 40 do k = k + 1 end
            local x, y = pos(math.floor((ks + k) / 2))
            out[#out + 1] = { k = ks % n, x = x, y = y, len = k - ks + 1 }
        end
        k = k + 1
    end
    return out
end

local function nearOtherCheckpoint(md, zi, R, x, y, key)
    for k2, cp in pairs(md.checkpoints) do
        if k2 ~= key and cp.zi == zi and cp.R == R and cp.cx
                and math.abs(cp.cx - x) + math.abs(cp.cy - y) < CHECK_SPACING then
            return true
        end
    end
    return false
end

-- Plans the checkpoint over the road at (x, y): parts, cx, cy; nil (no checkpoint here) or false (not loaded).
local function planCheckpoint(x, y)
    local axis, line, a, b = crossingAt(x, y)
    if not axis or b - a + 1 > CHECK_MAX_ROAD then return nil end
    local x1, y1, x2, y2
    if axis == "x" then x1, y1, x2, y2 = a - 6, line - 1, b + 7, line + 4
    else x1, y1, x2, y2 = line - 1, a - 6, line + 4, b + 7 end
    if not boxLoaded(x1, y1, x2, y2) then return false end
    local parts, cx, cy = checkpointParts(axis, line, a, b)
    if not parts then return nil end
    return parts, cx, cy, string.format("road %d-%d, %s", a, b, axis)
end

-- state: "post" (standing), "ruin", "gone", "none" (no checkpoint fits here).
local function workCheckpoint(md, zi, R, c, rstate)
    local key = zi .. ":" .. R .. ":c" .. c.k
    local cp = md.checkpoints[key]
    local st = cp and cp.state
    if rstate == "active" and st then return false end
    if rstate == "ruin" and st and st ~= "post" then return false end
    if st == "post" then                                          -- the line fell: knock it down
        if not boxLoaded(cp.cx - 8, cp.cy - 8, cp.cx + 8, cp.cy + 8) then return false end
        local out, items = ruinFrom(cp.parts, cp.cx, cp.cy, true)
        cp.state, cp.parts = "ruin", out
        log(string.format("checkpoint %s is now a ruin at %d,%d (crate with %d items)", key, cp.cx, cp.cy, items))
        return true
    end
    if c.len > 16 or nearOtherCheckpoint(md, zi, R, c.x, c.y, key) then
        md.checkpoints[key] = { state = "none", zi = zi, R = R }
        return true
    end
    local plan, cx, cy, what = planCheckpoint(c.x, c.y)
    if plan == false then return false end
    if not plan then md.checkpoints[key] = { state = "none", zi = zi, R = R } return true end
    if rstate == "active" then
        local parts = placeAll(plan)
        md.checkpoints[key] = { state = "post", zi = zi, R = R, cx = cx, cy = cy, parts = parts }
        log(string.format("checkpoint %s built at %d,%d (%s, %d pieces)", key, cx, cy, what, #parts))
    else                                                          -- fell before anyone saw it standing
        local out, items = ruinFrom(plan, cx, cy, false)
        md.checkpoints[key] = { state = "ruin", zi = zi, R = R, cx = cx, cy = cy, parts = out }
        log(string.format("checkpoint %s ruins at %d,%d (%s, crate with %d items)", key, cx, cy, what, items))
    end
    return true
end

-- Puts back missing pieces of a standing post or checkpoint. Returns how many.
local function repairParts(parts)
    local n = 0
    for _, p in ipairs(parts or {}) do
        local sq = getCell():getGridSquare(p.x, p.y, p.z)
        if sq and not hasSprite(sq, p.s) and placeTile(p) then n = n + 1 end
    end
    return n
end

local function announce(md, radius)
    local active = activeRing(radius)
    for R = RING_OUTER, RING_INNER + RING_STEP, -RING_STEP do
        if R > active and not md.fallen[tostring(R)] then
            md.fallen[tostring(R)] = true
            if md.initialized then
                say(string.format("The defense line %d tiles out has fallen. The camps hold the line at %d tiles now; the old posts lie in ruins.", R, active))
                log(string.format("line %d collapsed (safe radius %.0f)", R, radius))
            end
        end
    end
    md.initialized = true
end

local function nearAPlayer(players, x, y)
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and (p:getX() - x) ^ 2 + (p:getY() - y) ^ 2 <= NEAR * NEAR then return true end
    end
    return false
end

-- Clears fallen checkpoints past their ruin window, and every REPAIR_SECONDS puts back missing pieces
-- of standing posts and checkpoints near a player.
local lastRepair = 0
local function upkeep(md, players, radius, days, nowMs)
    local work = 0
    for key, cp in pairs(md.checkpoints) do
        if (cp.state == "post" or cp.state == "ruin") and ringState(cp.R, radius, days) == "gone"
                and nearAPlayer(players, cp.cx, cp.cy) and boxLoaded(cp.cx - 8, cp.cy - 8, cp.cx + 8, cp.cy + 8) then
            clearParts(cp.parts)
            md.checkpoints[key] = { state = "gone", zi = cp.zi, R = cp.R, cx = cp.cx, cy = cp.cy }
            log(string.format("checkpoint %s ruins cleared at %d,%d", key, cp.cx, cp.cy))
            work = work + 1
            if work >= MAX_WORK_PER_TICK then return end
        end
    end
    if nowMs - lastRepair < REPAIR_SECONDS * 1000 then return end
    lastRepair = nowMs
    local function repair(what, key, x, y, parts)
        if nearAPlayer(players, x, y) and boxLoaded(x - 8, y - 8, x + 8, y + 8) then
            local n = repairParts(parts)
            if n > 0 then log(string.format("%s %s repaired: %d piece(s)", what, key, n)) end
        end
    end
    for key, cp in pairs(md.checkpoints) do
        if cp.state == "post" then repair("checkpoint", key, cp.cx, cp.cy, cp.parts) end
    end
    for key, s in pairs(md.slots) do
        if s.state == "post" then repair("gate", key, s.x, s.y, s.parts) end
    end
end

local lastTick = 0
local function tick(nowMs)
    local h = heat()
    if not (h and h.safeRadius and h.serverDays and h.ZONES) then return end
    local md = data()
    local radius, days = h.safeRadius(), h.serverDays()
    announce(md, radius)
    local players = getOnlinePlayers()
    if not players or players:size() == 0 then return end
    upkeep(md, players, radius, days, nowMs)
    local work = 0
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and not p:isDead() then
            local px, py = p:getX(), p:getY()
            for zi, zc in ipairs(h.ZONES) do
                local dx, dy = px - zc[1], py - zc[2]
                local D = math.sqrt(dx * dx + dy * dy)
                if D > RING_INNER - NEAR and D < RING_OUTER + NEAR then
                    local phi = math.atan2(dy, dx)
                    for R = RING_OUTER, RING_INNER, -RING_STEP do
                        if math.abs(D - R) <= NEAR then
                            local rstate = ringState(R, radius, days)
                            if rstate == "active" or rstate == "ruin" then
                                -- checkpoints first, so they get the road shoulders before a field post does
                                for _, c in ipairs(ringCrossings(zc, R, px, py)) do
                                    if (c.x - px) ^ 2 + (c.y - py) ^ 2 <= NEAR * NEAR and workCheckpoint(md, zi, R, c, rstate) then
                                        work = work + 1
                                        if work >= MAX_WORK_PER_TICK then return end
                                    end
                                end
                            end
                            if rstate ~= "future" then
                                local n = slotCount(R)
                                local k0 = math.floor(phi / (2 * math.pi) * n + 0.5)
                                local span = math.ceil(NEAR / (2 * math.pi * R / n)) + 1
                                for kk = k0 - span, k0 + span do
                                    local k = kk % n
                                    local a = 2 * math.pi * k / n
                                    local sx, sy = zc[1] + R * math.cos(a), zc[2] + R * math.sin(a)
                                    if (sx - px) ^ 2 + (sy - py) ^ 2 <= NEAR * NEAR then
                                        if workSlot(md, zi, zc, R, k, n, rstate) then
                                            work = work + 1
                                            if work >= MAX_WORK_PER_TICK then return end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Shared with PE_Sentries (the camp checkpoints) and the offline sim (/root/defenseline_sim.lua).
PEDefenseLine = { activeRing = activeRing, ringState = ringState, collapseDay = collapseDay, slotCount = slotCount,
                  rollItem = rollItem, segmentParts = segmentParts, planSegment = planSegment,
                  checkpointParts = checkpointParts,
                  placeAll = placeAll, clearParts = clearParts, repairParts = repairParts, setLight = setLight,
                  crossingAt = crossingAt, ruinFrom = ruinFrom }

Events.OnTick.Add(function()
    local now = getTimestampMs()
    if now - lastTick < TICK_SECONDS * 1000 then return end
    lastTick = now
    local ok, err = pcall(tick, now)
    if not ok then log("tick error: " .. tostring(err)) end
    local okL, errL = pcall(sendLights, now)
    if not okL then log("lights error: " .. tostring(errL)) end
end)

-- Admin -----------------------------------------------------------------------------------------------------
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
    PEAdminCommands.lines = function()
        local h = heat()
        if not (h and h.safeRadius) then return adminLog("lines: PE_DinoHeat not loaded") end
        local radius, days = h.safeRadius(), h.serverDays()
        local md = data()
        local counts = {}
        for _, s in pairs(md.slots) do counts[s.state or "?"] = (counts[s.state or "?"] or 0) + 1 end
        local parts = {}
        for R = RING_OUTER, RING_INNER, -RING_STEP do
            local st = ringState(R, radius, days)
            if st ~= "future" and st ~= "gone" then parts[#parts + 1] = R .. " " .. st end
        end
        local cps = {}
        for _, c in pairs(md.checkpoints) do cps[c.state or "?"] = (cps[c.state or "?"] or 0) + 1 end
        local nl = 0
        for _ in pairs(lights().lamps) do nl = nl + 1 end
        adminLog(string.format("lines: safe radius %.0f (day %.2f) | %s | posts post=%d ruin=%d gone=%d none=%d | checkpoints post=%d ruin=%d gone=%d none=%d | lamps lit %d | samples %d",
            radius, days, table.concat(parts, ", "), counts.post or 0, counts.ruin or 0, counts.gone or 0,
            counts.none or 0, cps.post or 0, cps.ruin or 0, cps.gone or 0, cps.none or 0, nl, #md.samples))
    end
    PEAdminCommands.line = function(args)
        local p = findPlayer(args[1] or "")
        if not p then return adminLog("player not online: " .. tostring(args[1])) end
        if args[2] == "checkpoint" then
            -- the nearest road square to the player (up to 25 tiles), then a checkpoint over it
            local px, py = math.floor(p:getX()), math.floor(p:getY())
            for r = 0, 25 do
                for dx = -r, r do
                    for dy = -r, r do
                        if (math.abs(dx) == r or math.abs(dy) == r) and roadAt(px + dx, py + dy) then
                            local plan, cx, cy, what = planCheckpoint(px + dx, py + dy)
                            if plan then
                                local parts = placeAll(plan)
                                local md = data()
                                md.samples[#md.samples + 1] = { x = cx, y = cy, parts = parts }
                                return adminLog(string.format("line: sample checkpoint at %d,%d (%s, %d pieces)", cx, cy, what, #parts))
                            end
                        end
                    end
                end
            end
            return adminLog("line: no road within 25 tiles of " .. p:getUsername() .. " that fits a checkpoint (max " .. CHECK_MAX_ROAD .. " wide)")
        end
        local kind = args[2] == "ruin" and "ruin" or "gate"
        local h = heat()
        local zi = h and h.nearestZone and h.nearestZone(p:getX(), p:getY()) or 1
        local zc = h and h.ZONES and h.ZONES[zi] or { p:getX(), p:getY() }
        local plan, lx, ly = planSegment(p:getX() + 8, p:getY(), true, zc)
        if not plan then
            local cx, cy = math.floor(p:getX() + 8), math.floor(p:getY())
            local tally, cell = {}, getCell()
            for dx = -SEARCH - 2, SEARCH + 2 do
                for dy = -SEARCH - 1, SEARCH do
                    local why = squareReason(cell:getGridSquare(cx + dx, cy + dy, 0)) or "ok"
                    tally[why] = (tally[why] or 0) + 1
                end
            end
            local list = {}
            for why, n in pairs(tally) do list[#list + 1] = why .. "=" .. n end
            table.sort(list)
            return adminLog(string.format("line: no spot for a gate near %d,%d (loaded=%s) squares: %s", cx, cy,
                tostring(plan ~= false), table.concat(list, ", ")))
        end
        local parts, items
        if kind == "gate" then parts = placeAll(plan)
        else parts, items = ruinFrom(plan, lx, ly, false) end
        local md = data()
        md.samples[#md.samples + 1] = { x = lx, y = ly, parts = parts }
        adminLog(string.format("line: sample %s at %d,%d (%d pieces%s)", kind, lx, ly, #parts,
            items and (", crate with " .. items .. " items") or ""))
    end
    PEAdminCommands.lineclear = function()
        local md = data()
        local keep, n = {}, 0
        for _, s in ipairs(md.samples) do
            if boxLoaded(s.x - 8, s.y - 8, s.x + 8, s.y + 8) then clearParts(s.parts); n = n + 1
            else keep[#keep + 1] = s end
        end
        md.samples = keep
        adminLog(string.format("lineclear: removed %d sample(s), %d not loaded (kept for later)", n, #keep))
    end
end

Events.OnServerStarted.Add(function()
    log(string.format("active: lines every %d tiles (%d -> %d), a gate every ~%d tiles, ruins for %d days",
        RING_STEP, RING_OUTER, RING_INNER, POST_SPACING, RUIN_DAYS))
end)
