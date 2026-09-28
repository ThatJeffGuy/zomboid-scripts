-- ZEM_Lights.lua  (client)
-- Lights for the Zomboid Evolved defense-line checkpoints. The server keeps the lamp positions in the
-- global ModData "PELights" (lamps = { ["x,y,z"] = true }, see PE_DefenseLine.lua on the server) and
-- transmits it on every change. Each client draws a steady warm light at every lamp near the player:
-- it never burns out and there is nothing on the lamp to take. Lights go out when the server drops a
-- lamp (its line fell). Each lamp is two stacked lights (double brightness, the user's ask).
-- The lamps are also the camp's hidden guns: the server sends "ZEM shot" (x, y, z) when one fires, and
-- this plays a rifle shot there with a short muzzle flash. Does nothing outside multiplayer.
if isServer() then return end

local KEY = "PELights"
local RANGE = 80                      -- tiles; lamps further away have no light
local RADIUS = 9                      -- light radius in tiles
local R, G, B = 1.0, 0.72, 0.42       -- warm lamp light
local CHECK_TICKS = 120               -- about every 2 seconds
local LIGHTS_PER_LAMP = 2
local SHOT_SOUND = "MSR788Shoot"      -- a hunting rifle
local FLASH_TICKS = 30                -- about half a second (the lighting only picks a new light up every few frames)

local lamps = {}                      -- "x,y,z" -> true, from the server
local lit = {}                        -- "x,y,z" -> { IsoLightSource, ... }
local flashes = {}                    -- { light = IsoLightSource, ticks = n }
local ticks = 0

local function receive(key, data)
    if key ~= KEY or type(data) ~= "table" then return end   -- a request for data the server hasn't got yet answers false
    lamps = type(data.lamps) == "table" and data.lamps or {}
end

local function refresh()
    local player = getPlayer()
    local cell = getCell()
    if not (player and cell) then return end
    local px, py = player:getX(), player:getY()
    for key, lights in pairs(lit) do
        local x, y = key:match("^(-?%d+),(-?%d+),")
        x, y = tonumber(x), tonumber(y)
        if not lamps[key] or not x or math.abs(x - px) > RANGE or math.abs(y - py) > RANGE then
            for _, light in ipairs(lights) do pcall(function() cell:removeLamppost(light) end) end
            lit[key] = nil
        end
    end
    for key in pairs(lamps) do
        if not lit[key] then
            local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
            x, y, z = tonumber(x), tonumber(y), tonumber(z)
            if x and math.abs(x - px) <= RANGE and math.abs(y - py) <= RANGE then
                local lights = {}
                for _ = 1, LIGHTS_PER_LAMP do
                    local ok, light = pcall(function()
                        local l = IsoLightSource.new(x, y, z, R, G, B, RADIUS)
                        cell:addLamppost(l)
                        return l
                    end)
                    if ok and light then lights[#lights + 1] = light end
                end
                if #lights > 0 then lit[key] = lights end
            end
        end
    end
end

-- A lamp gun fired: the shot and a muzzle flash at the lamp.
local function onServerCommand(module, command, args)
    if module ~= "ZEM" or command ~= "shot" or type(args) ~= "table" then return end
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z) or 0
    local cell = getCell()
    if not (x and y and cell) then return end
    local sq = cell:getGridSquare(x, y, z)
    if sq then
        local played = pcall(function() sq:playSound(SHOT_SOUND) end)
        if not played then pcall(function() getSoundManager():PlayWorldSound(SHOT_SOUND, sq, 0, 60, 1.0, false) end) end
    end
    local ok, light = pcall(function()
        local l = IsoLightSource.new(x, y, z, 1.0, 0.95, 0.8, 12)
        cell:addLamppost(l)
        return l
    end)
    if ok and light then flashes[#flashes + 1] = { light = light, ticks = FLASH_TICKS } end
end

Events.OnReceiveGlobalModData.Add(receive)
Events.OnServerCommand.Add(onServerCommand)

Events.OnInitGlobalModData.Add(function()
    if not isClient() then return end
    pcall(function() ModData.request(KEY) end)
end)

Events.OnTick.Add(function()
    if not isClient() then return end
    if #flashes > 0 then
        local keep, cell = {}, getCell()
        for _, f in ipairs(flashes) do
            f.ticks = f.ticks - 1
            if f.ticks > 0 then keep[#keep + 1] = f
            elseif cell then pcall(function() cell:removeLamppost(f.light) end) end
        end
        flashes = keep
    end
    ticks = ticks + 1
    if ticks < CHECK_TICKS then return end
    ticks = 0
    local empty = true
    for _ in pairs(lamps) do empty = false break end
    if empty then                                     -- nothing received yet: ask again (no `next` in PZ's Lua)
        pcall(function() ModData.request(KEY) end)
    end
    local ok, err = pcall(refresh)
    if not ok then print("[ZEM-Lights] " .. tostring(err)) end
end)
