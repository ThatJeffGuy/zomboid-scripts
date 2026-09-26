-- Zomboid Evolved server-script loader (dedicated server only; does nothing on players' games).
--
-- The server's own gameplay scripts (dino presets, safe zones, damage model...) are kept outside
-- the game and mod folders, in <server Zomboid dir>/Lua/ZomboidEvolved/, and run from here with
-- loadstring. That keeps them out of the multiplayer Lua checksum (players never have them), so
-- the server can keep DoLuaChecksum=true while still changing those scripts without a mod update.
--
-- load.txt in that folder lists the scripts to run, one file name per line, in order
-- (blank lines and lines starting with # are ignored).
if isClient() or not isServer() then return end

local DIR = "ZomboidEvolved"

local function log(msg) print("[ZE-Loader] " .. msg) end

local function readAll(path)
    local reader = getFileReader(path, false)
    if not reader then return nil end
    local lines = {}
    local line = reader:readLine()
    while line ~= nil do
        lines[#lines + 1] = line
        line = reader:readLine()
    end
    reader:close()
    return table.concat(lines, "\n")
end

-- B42.20.4 Stable disabled loadstring (security hotfix); 42.21 re-enables it. Until then the
-- server keeps its scripts in the game's media/lua/server with DoLuaChecksum=false.
if type(loadstring) ~= "function" then
    log("loadstring is unavailable on this game build (disabled in 42.20.4, back in 42.21); server scripts not loaded from Lua/" .. DIR)
    return
end

local manifest = readAll(DIR .. "/load.txt")
if not manifest then
    log("no " .. DIR .. "/load.txt in the server's Lua folder; nothing to load")
    return
end

ZomboidEvolvedServer = ZomboidEvolvedServer or { loaded = {} }
local loaded, failed = 0, 0
for name in manifest:gmatch("[^\n]+") do
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name ~= "" and name:sub(1, 1) ~= "#" then
        local src = readAll(DIR .. "/" .. name)
        if not src then
            log("MISSING " .. name); failed = failed + 1
        else
            local chunk, err = loadstring(src, "@" .. DIR .. "/" .. name)
            if not chunk then
                log("COMPILE ERROR in " .. name .. ": " .. tostring(err)); failed = failed + 1
            else
                local ok, runErr = pcall(chunk)
                if ok then
                    ZomboidEvolvedServer.loaded[name] = true; loaded = loaded + 1
                else
                    log("RUNTIME ERROR in " .. name .. ": " .. tostring(runErr)); failed = failed + 1
                end
            end
        end
    end
end
log(string.format("loaded %d server script(s) from Lua/%s%s", loaded, DIR, failed > 0 and (", " .. failed .. " FAILED") or ""))
