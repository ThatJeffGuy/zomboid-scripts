-- PE_AdminCmd.lua  (server-side only)
-- Lets the server admin trigger a few whitelisted server-side actions from the shell, for testing
-- things that need a player in game. RCON can't run Lua, so this polls Zomboid/Lua/PE/cmd.txt every
-- POLL_SECONDS. Each line is "<seq> <command> [args...]"; a line runs once (seq must be higher than
-- the last one run). No arbitrary code: only the commands below.
--   <seq> clan <clan name or cid> <size> <username> [distance] [angle]   spawn a Bandits clan group near a player
--   <seq> where                                                  log online players' positions
--   <seq> dino <raptor|carno|trex|pachy|stego|anky> <username> [distance] [angle]  spawn one dinosaur near a player
--        (angle in degrees, 0 = east/+x, 90 = south/+y; random if omitted)
--   <seq> bandits [radius]                                       log live bandits (name, clan, weapons, hp)
--                                                                within radius of any player (default 150)
--   <seq> corpses [radius]                                       log animal corpses (butcher data) within radius
--                                                                of any player (default 30, max 60)
-- Results are logged as "[PE-Admin]" (and relayed to chat when prefixed [PE-Say]).
if isClient() then return end

local POLL_SECONDS = 5
local FILE = "PE" .. getFileSeparator() .. "cmd.txt"   -- Zomboid/Lua/PE/cmd.txt (root-level files are refused)
local lastSeq = nil
local lastPoll = 0
local warnedNoFile = false

local function log(msg) print("[PE-Admin] " .. msg) end

local function findPlayer(name)
    local players = getOnlinePlayers()
    if not players then return nil end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and p:getUsername():lower() == tostring(name):lower() then return p end
    end
    return nil
end

local function clanId(nameOrCid)
    local data = BanditCustom and BanditCustom.clanData
    if type(data) ~= "table" then return nil end
    if data[nameOrCid] then return nameOrCid end
    for cid, clan in pairs(data) do
        local g = type(clan) == "table" and clan.general
        if g and tostring(g.name):lower() == tostring(nameOrCid):lower() then return cid end
    end
    return nil
end

PEAdminCommands = PEAdminCommands or {}   -- other PE_* scripts add commands here (e.g. PE_Outposts)
local commands = PEAdminCommands

commands.clan = function(args)
    local who, size, dist, deg = args[3], tonumber(args[2]) or 2, tonumber(args[4]) or 25, tonumber(args[5])
    if not (BanditServer and BanditServer.Spawner and BanditServer.Spawner.Clan) then return log("Bandits spawner not available") end
    local cid = clanId(args[1] or "")
    if not cid then return log("unknown clan: " .. tostring(args[1])) end
    local p = findPlayer(who)
    if not p then return log("player not online: " .. tostring(who)) end
    local ang = deg and math.rad(deg) or ZombRandFloat(0, math.pi * 2)
    local x, y = math.floor(p:getX() + math.cos(ang) * dist), math.floor(p:getY() + math.sin(ang) * dist)
    BanditServer.Spawner.Clan(p, { cid = cid, size = size, x = x, y = y, z = p:getZ() })
    log(string.format("spawned clan %s x%d near %s at %d,%d", tostring(args[1]), size, p:getUsername(), x, y))
end

commands.dino = function(args)
    local label, who, dist, deg = args[1], args[2], tonumber(args[3]) or 20, tonumber(args[4])
    if not (DinoPopulation and DinoPopulation.speciesConfig and DinoPopulation.spawnAnimal) then return log("dino mod not available") end
    local cfg = DinoPopulation.speciesConfig(tostring(label))
    if not cfg then return log("unknown species: " .. tostring(label)) end
    local p = findPlayer(who)
    if not p then return log("player not online: " .. tostring(who)) end
    local cell = getCell()
    for try = 1, 20 do
        local ang = deg and math.rad(deg + (try - 1) * 7) or ZombRandFloat(0, math.pi * 2)
        local sq = cell:getGridSquare(math.floor(p:getX() + math.cos(ang) * dist), math.floor(p:getY() + math.sin(ang) * dist), p:getZ())
        if sq and DinoPopulation.isUsableOutdoorSquare(sq) and DinoPopulation.spawnAnimal(sq, cfg) then
            return log(string.format("spawned %s near %s at %d,%d", label, p:getUsername(), sq:getX(), sq:getY()))
        end
    end
    log("no usable outdoor square for " .. tostring(label) .. " near " .. p:getUsername())
end

commands.where = function()
    local players = getOnlinePlayers()
    if not players or players:size() == 0 then return log("no players online") end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        log(string.format("%s at %d,%d,%d%s", p:getUsername(), math.floor(p:getX()), math.floor(p:getY()), p:getZ(), p:isDead() and " (dead)" or ""))
    end
end

local function clanName(cid)
    local data = BanditCustom and BanditCustom.clanData
    local c = type(data) == "table" and data[cid]
    return c and c.general and c.general.name or tostring(cid)
end

local function weaponName(w)
    if type(w) == "table" then
        if not w.name then return "-" end
        return string.format("%s[%s/%s]", w.name, tostring(w.bulletsLeft), tostring(w.ammoCount or w.magCount))
    end
    return tostring(w or "-")
end

commands.bandits = function(args)
    local radius = tonumber(args[1]) or 150
    local cell = getCell()
    local list = cell and cell:getZombieList()
    local players = getOnlinePlayers()
    if not (list and players) then return log("no cell/players") end
    local n = 0
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        local id = z and z:getPersistentOutfitID()
        local gmd = id and GetBanditClusterData and GetBanditClusterData(id)
        local brain = type(gmd) == "table" and gmd[id]
        if brain then
            local near, best = nil, math.huge
            for j = 0, players:size() - 1 do
                local p = players:get(j)
                local d = math.sqrt((p:getX() - z:getX()) ^ 2 + (p:getY() - z:getY()) ^ 2)
                if d < best then near, best = p, d end
            end
            if best <= radius then
                n = n + 1
                local w = brain.weapons or {}
                log(string.format("bandit %s (%s) at %d,%d %.0f tiles from %s, hp %.2f%s | melee %s | primary %s | secondary %s",
                    tostring(brain.fullname), clanName(brain.cid), math.floor(z:getX()), math.floor(z:getY()), best,
                    near and near:getUsername() or "?", z:getHealth(), z:isDead() and " DEAD" or "",
                    tostring(w.melee), weaponName(w.primary), weaponName(w.secondary)))
            end
        end
    end
    log(n .. " bandit(s) within " .. radius .. " tiles of a player")
end

-- Animal corpse butcher data: hasAnimalParts() (the "parts" ModData flag set by vanilla setAnimalBodyData)
-- decides whether the loot-window "Butcher" option shows up at all.
local function describeCorpse(b)
    local md, sq = b:getModData(), b:getSquare()
    return string.format("%s%s at %d,%d,%d: parts=%s skeleton=%s rotStage=%s leather=%s head=%s",
        tostring(md.AnimalType), tostring(md.AnimalBreed), sq:getX(), sq:getY(), sq:getZ(),
        tostring(md.parts), tostring(md.skeleton), tostring(md.animalRotStage), tostring(md.leather), tostring(md.head))
end

local function animalCorpsesAround(x, y, z, radius, seen, out)
    local cell = getCell()
    for dx = -radius, radius do
        for dy = -radius, radius do
            local sq = cell:getGridSquare(x + dx, y + dy, z)
            local bodies = sq and sq:getDeadBodys()
            if bodies then
                for i = 0, bodies:size() - 1 do
                    local b = bodies:get(i)
                    if b and b:isAnimal() and not seen[b] then seen[b] = true out[#out + 1] = b end
                end
            end
        end
    end
end

commands.corpses = function(args)
    local radius = math.min(tonumber(args[1]) or 30, 60)
    local players = getOnlinePlayers()
    if not players or players:size() == 0 then return log("no players online") end
    local seen, found = {}, {}
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        animalCorpsesAround(math.floor(p:getX()), math.floor(p:getY()), p:getZ(), radius, seen, found)
    end
    for _, b in ipairs(found) do log("corpse " .. describeCorpse(b)) end
    log(#found .. " animal corpse(s) within " .. radius .. " tiles of a player")
end

local function poll()
    local reader = getFileReader(FILE, false)
    if not reader then
        if not warnedNoFile then warnedNoFile = true log("cannot open " .. FILE) end
        return
    end
    local lines = {}
    while true do
        local line = reader:readLine()
        if not line then break end
        lines[#lines + 1] = line
    end
    reader:close()
    if lastSeq == nil then          -- first read after boot: skip everything already in the file
        local maxSeq = 0
        for _, line in ipairs(lines) do
            local seq = tonumber(line:match("^%s*(%d+)"))
            if seq and seq > maxSeq then maxSeq = seq end
        end
        lastSeq = maxSeq
        return
    end
    for _, line in ipairs(lines) do
        local parts = {}
        for w in line:gmatch("%S+") do parts[#parts + 1] = w end
        local seq, cmd = tonumber(parts[1]), parts[2]
        if seq and cmd then
            if seq > lastSeq then
                lastSeq = seq
                local fn = commands[cmd]
                if fn then
                    local rest = {}
                    for i = 3, #parts do rest[#rest + 1] = parts[i] end
                    local ok, err = pcall(fn, rest)
                    if not ok then log("command failed: " .. line .. " -> " .. tostring(err)) end
                else
                    log("unknown command: " .. line)
                end
            end
        end
    end
end

Events.OnTick.Add(function()
    local now = getTimestampMs()
    if now - lastPoll < POLL_SECONDS * 1000 then return end
    lastPoll = now
    local ok, err = pcall(poll)
    if not ok then log("poll error: " .. tostring(err)) end
end)
Events.OnServerStarted.Add(function() log("admin command poller active (" .. FILE .. ")") end)
