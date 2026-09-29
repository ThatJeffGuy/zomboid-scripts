-- ZEM_ModFixes.lua  (shared: server and every client)
-- Small compatibility shims for other mods on the Zomboid Evolved server.
--
-- Archery Nexus (3617854007, R5_AimState.lua): its OnEquipPrimary handler calls
-- player:setAnimVariable(name, value), which IsoPlayer doesn't have in B42.21 (the method lives on
-- timed actions; characters use setVariable). It threw "Object tried to call nil" on every equip and
-- the bow's aim animation flag never got set. This adds setAnimVariable to IsoPlayer, passing
-- straight through to setVariable, so the mod's own handler works unchanged.
local function shimSetAnimVariable()
    local mt = __classmetatables and IsoPlayer and __classmetatables[IsoPlayer.class]
    local index = mt and mt.__index
    if type(index) == "table" and index.setAnimVariable == nil then
        index.setAnimVariable = function(self, name, value) self:setVariable(name, value) end
        print("[ZEM] Archery Nexus fix: IsoPlayer:setAnimVariable -> setVariable")
    end
end

local ok, err = pcall(shimSetAnimVariable)
if not ok then print("[ZEM] Archery Nexus fix failed: " .. tostring(err)) end
