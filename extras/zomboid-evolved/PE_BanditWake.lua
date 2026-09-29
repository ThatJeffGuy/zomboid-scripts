-- PE_BanditWake.lua  (server-side only)
-- Bandits mod bug (2026-09-29): when a bandit hits a player the client sends Commands.WakeEveryone
-- with an empty table, which arrives on the server as nil args. The mod's own OnClientCommand
-- handler does pairs(args) first and throws "Expected a table", so nobody is woken. This handler
-- runs the mod's WakeEveryone itself for that case. The mod's error line still appears in the log
-- (its listener is a local we can't remove), but sleeping players now wake when bandits attack.
if isClient() then return end

local wakes = 0

local function onClientCommand(module, command, player, args)
    if module ~= "Commands" or command ~= "WakeEveryone" or args ~= nil then return end
    local cmds = BanditServer and BanditServer.Commands
    if not (cmds and cmds.WakeEveryone) then return end
    cmds.WakeEveryone(player, {})
    wakes = wakes + 1
    if wakes == 1 or wakes % 50 == 0 then
        print("[PE-BanditWake] woke everyone for a bandit attack (" .. wakes .. " this boot).")
    end
end

Events.OnClientCommand.Add(onClientCommand)
print("[PE-BanditWake] active: fixes the Bandits mod's nil-args WakeEveryone.")
