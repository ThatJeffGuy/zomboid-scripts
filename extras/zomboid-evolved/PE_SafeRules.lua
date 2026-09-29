-- PE_SafeRules.lua  (server-side only)
-- Rules inside the camps' shrinking safe zones (the user, 2026-09-29): inside the standing defense line's
-- sandbag ring (PE_DefenseLine: activeRing of the safe radius, round every camp center):
--   * no building: building, placing furniture, barricading and multi-stage builds are refused;
--   * no destroying: sledgehammer destroy, dismantling and scrapping furniture are refused;
--   * fire doesn't spread: a fire burns where it was started; any square it spreads to is put out
--     (campfires and other permanent fires are left alone);
--   * PvP and raiding stay allowed (nothing here touches combat, doors, windows or looting).
-- In B42 multiplayer the server runs a timed action through serverStart/complete (NetTimedAction), not
-- isValid, so complete() is wrapped (refused = returns false, nothing happens) as well as isValid (single
-- player / client checks); the build menu goes through ISBuildIsoEntity:create on the server. The player
-- gets a "denied" message (ZEM_SafeZone.lua in Zomboid Evolved Core shows it). Admins are exempt.
-- Sleeping stays possible (the user, 2026-09-29): beds (straw, twig, any bed), tents, bedrolls and
-- campfires may be built or placed anywhere (SLEEP_WORDS, matched on the build/item name).
-- The camps' own Aegis zones keep their stricter rules on top. Log prefix "[PE-Rules]".
if isClient() then return end

local FIRE_SECONDS = 1
local FIRE_RANGE = 30                  -- tiles round each player swept for fires
local FIRE_LEVELS = 2                  -- z 0..FIRE_LEVELS-1
local NO_SPREAD = 1000000000
local DENY_GAP_MS = 3000
local SLEEP_WORDS = { "bed", "tent", "camp", "sleep", "cot", "mattress", "hammock", "firepit", "fire pit" }

local function sleepThing(...)
    for _, name in ipairs({ ... }) do
        local n = type(name) == "string" and name:lower() or ""
        for _, w in ipairs(SLEEP_WORDS) do
            if n:find(w, 1, true) then return true end
        end
    end
    return false
end

local function log(msg) print("[PE-Rules] " .. msg) end

-- Inside a zone: within the standing line of any camp.
local function lineRadius()
    local h, DL = PEDinoHeat, PEDefenseLine
    if not (h and h.safeRadius and DL and DL.activeRing) then return nil end
    return DL.activeRing(h.safeRadius())
end

local function inSafe(x, y)
    local R = lineRadius()
    if not R then return false end
    for _, zc in ipairs(PEDinoHeat.ZONES) do
        if (x + 0.5 - zc[1]) ^ 2 + (y + 0.5 - zc[2]) ^ 2 < R * R then return true end
    end
    return false
end

local function isAdmin(p)
    local ok, level = pcall(function() return p:getAccessLevel() end)
    level = ok and tostring(level):lower() or ""
    return level == "admin" or level == "moderator"
end

-- The player within 6 tiles of (x, y), for calls that don't carry their character.
local function nearestPlayer(x, y)
    local players = getOnlinePlayers()
    local best, bestD = nil, 36
    for i = 0, players and players:size() - 1 or -1 do
        local p = players:get(i)
        local d = p and (p:getX() - x) ^ 2 + (p:getY() - y) ^ 2
        if d and d <= bestD then best, bestD = p, d end
    end
    return best
end

local deniedAt = {}
local function deny(p, what)
    local name = p and p:getUsername() or "?"
    local now = getTimestampMs()
    if deniedAt[name .. what] and now - deniedAt[name .. what] < DENY_GAP_MS then return end
    deniedAt[name .. what] = now
    if p then pcall(function() sendServerCommand(p, "ZEM", "denied", { what = what }) end) end
    log(string.format("%s: %s refused inside the safe zone", name, what))
end

-- Wraps cls[method]. where(self, ...) returns the square the action works on, or { x, y }.
-- only(self) limits it to some modes. A refused call returns `refused` without running the original.
local wrapped = {}
local function wrap(clsName, method, what, where, only, refused)
    local cls = _G[clsName]
    local key = clsName .. "." .. method
    if not cls or type(cls[method]) ~= "function" or wrapped[key] then return false end
    local orig = cls[method]
    cls[method] = function(self, ...)
        local ok, blocked, who = pcall(function(...)
            if only and not only(self) then return false end
            local sq = where(self, ...)
            local x, y
            if type(sq) == "table" and sq[1] then x, y = sq[1], sq[2]
            elseif sq and sq.getX then x, y = sq:getX(), sq:getY() end
            local p = self.character
            if not p and x then p = nearestPlayer(x, y) end
            if not p or isAdmin(p) then return false end
            if not x then x, y = p:getX(), p:getY() end
            return inSafe(math.floor(x), math.floor(y)), p
        end, ...)
        if ok and blocked then
            deny(who, what)
            return refused
        end
        return orig(self, ...)
    end
    wrapped[key] = true
    return true
end

local function sqOf(o) return o and o.getSquare and o:getSquare() or nil end

local function install()
    local n = 0
    local specs = {
        { "ISDestroyStuffAction", "destroying", function(self) return sqOf(self.item) end },
        { "ISDismantleAction", "dismantling", function(self) return sqOf(self.thumpable) end },
        { "ISBarricadeAction", "barricading", function(self) return sqOf(self.item) end },
        { "ISMultiStageBuild", "building", function(self) return sqOf(self.item) end },
    }
    for _, sp in ipairs(specs) do
        if wrap(sp[1], "isValid", sp[2], sp[3], nil, false) then n = n + 1 end
        if wrap(sp[1], "complete", sp[2], sp[3], nil, false) then n = n + 1 end
    end
    local function moveMode(self)
        if self.mode == "scrap" then return true end
        if self.mode ~= "place" then return false end
        local item = self.item
        local ok, allowed = pcall(function()
            return sleepThing(item and item:getName(), item and item:getFullType(),
                self.moveProps and self.moveProps.name, self.origSpriteName)
        end)
        return not (ok and allowed)
    end
    local function notSleep(self) return not sleepThing(self.name) end
    local function moveWhat(self) return self.square end
    if wrap("ISMoveablesAction", "isValid", "placing or scrapping furniture", moveWhat, moveMode, false) then n = n + 1 end
    if wrap("ISMoveablesAction", "complete", "placing or scrapping furniture", moveWhat, moveMode, false) then n = n + 1 end
    if wrap("ISBuildIsoEntity", "isValid", "building", function(self, square) return square end, notSleep, false) then n = n + 1 end
    if wrap("ISBuildIsoEntity", "create", "building", function(self, x, y) return { x, y } end, notSleep, nil) then n = n + 1 end
    return n
end

-- Fire. A higher spread delay alone didn't hold (live test 2026-09-29: a Molotov kept creeping a square
-- at a time), so: fire squares are remembered as they're first seen. A NEW fire square next to one seen
-- on an earlier sweep is spread and is put out at once; a new fire with no older fire beside it is a
-- fresh ignition (a Molotov, a lit fire) and burns where it started, spread delay pushed out of reach.
-- Campfires and other permanent fires are never touched.
local seenFire = {}                    -- "x,y,z" -> sweep number first seen
local sweepNo = 0

local function burningHere(sq)
    local objs = sq:getObjects()
    for k = 0, objs:size() - 1 do
        local o = objs:get(k)
        if instanceof(o, "IsoFire") and not o:isPermanent() and not o:isCampfire() then return o end
    end
    return nil
end

-- Puts a square's fire out on the server AND on every client. transmitStopFire only works from a
-- client (it did nothing here in the live test); removing the fire object with the transmitting call
-- tells the clients, then extinctFire drops it from the fire manager and clears the burning flag.
local function putOut(sq)
    local objs = sq:getObjects()
    for k = objs:size() - 1, 0, -1 do
        local o = objs:get(k)
        if instanceof(o, "IsoFire") and not o:isPermanent() and not o:isCampfire() then
            pcall(function() sq:transmitRemoveItemFromSquare(o) end)
            pcall(function() o:extinctFire() end)
        end
    end
    pcall(function() sq:getProperties():unset(IsoFlagType.burning) end)
end

local function fireSweep()
    local players = getOnlinePlayers()
    if not players or players:size() == 0 then return end
    local cell = getCell()
    local R = lineRadius()
    if not R then return end
    sweepNo = sweepNo + 1
    local present = {}
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p then
            local px, py = math.floor(p:getX()), math.floor(p:getY())
            local near = false
            for _, zc in ipairs(PEDinoHeat.ZONES) do
                if (px - zc[1]) ^ 2 + (py - zc[2]) ^ 2 < (R + FIRE_RANGE) ^ 2 then near = true end
            end
            if near then
                for z = 0, FIRE_LEVELS - 1 do
                    for x = px - FIRE_RANGE, px + FIRE_RANGE do
                        for y = py - FIRE_RANGE, py + FIRE_RANGE do
                            local sq = cell:getGridSquare(x, y, z)
                            if sq and sq:haveFire() and inSafe(x, y) then
                                local fire = burningHere(sq)
                                if fire then
                                    local key = x .. "," .. y .. "," .. z
                                    present[key] = true
                                    if not seenFire[key] then
                                        local spread = false
                                        for dx = -1, 1 do
                                            for dy = -1, 1 do
                                                local nk = (x + dx) .. "," .. (y + dy) .. "," .. z
                                                if (dx ~= 0 or dy ~= 0) and seenFire[nk] and seenFire[nk] < sweepNo then spread = true end
                                            end
                                        end
                                        if spread then
                                            putOut(sq)
                                            log(string.format("fire spreading to %d,%d,%d put out", x, y, z))
                                        else
                                            seenFire[key] = sweepNo
                                            pcall(function() fire:setSpreadDelay(NO_SPREAD) end)
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
    -- forget fires that went out, so the ground can burn again later
    local gone = {}
    for key in pairs(seenFire) do if not present[key] then gone[#gone + 1] = key end end
    for _, key in ipairs(gone) do seenFire[key] = nil end
end

local lastFire = 0
Events.OnTick.Add(function()
    local now = getTimestampMs()
    if now - lastFire < FIRE_SECONDS * 1000 then return end
    lastFire = now
    local ok, err = pcall(fireSweep)
    if not ok then log("fire sweep error: " .. tostring(err)) end
end)

Events.OnServerStarted.Add(function()
    local ok, n = pcall(install)
    log(string.format("active: no building / no destroying / fire doesn't spread inside the standing line; %s check(s) installed",
        ok and tostring(n) or ("FAILED " .. tostring(n))))
end)

-- Test helpers for the admin cmd.txt poller (2026-09-29): "day [hour]" sets the time of day (default 10),
-- "heal <user>" is Aegis's full heal (server object, then the client).
if PEAdminCommands then
    local function adminLog(msg) print("[PE-Admin] " .. msg) end
    PEAdminCommands.day = function(args)
        local hour = tonumber(args[1]) or 10
        getGameTime():setTimeOfDay(hour)
        pcall(function() getClimateManager():forceDayInfoUpdate() end)
        pcall(function() broadcastDate() end)
        adminLog("day: time of day set to " .. hour .. ":00")
    end
    PEAdminCommands.heal = function(args)
        local players = getOnlinePlayers()
        for i = 0, players and players:size() - 1 or -1 do
            local p = players:get(i)
            if p and p:getUsername():lower() == tostring(args[1]):lower() then
                local ok = pcall(function() AegisShared.fullHeal(p) end)
                pcall(function() sendServerCommand(p, "AegisAdmin", "heal", {}) end)
                return adminLog("heal: " .. p:getUsername() .. (ok and " fully healed" or " heal FAILED (Aegis missing?)"))
            end
        end
        adminLog("heal: player not online: " .. tostring(args[1]))
    end
end
