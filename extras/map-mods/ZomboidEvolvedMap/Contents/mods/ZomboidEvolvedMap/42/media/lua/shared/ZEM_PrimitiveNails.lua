-- Haiku Primitive (Workshop 3649911353) lets Bamboo Nails stand in for nails in
-- vanilla build/craft recipes, but its itemPatch.lua reads the input list through
-- reflection (getClassField), which 42.21 refuses outside debug mode, so the patch
-- never applies. InputScript:getItems() returns the same live list, so redo it here.
-- Does nothing unless Haiku Primitive is loaded.

local NAIL = "Base.Nails"
local ADD = { "Primitive.BambooNails" }

local RECIPES = {
    -- building recipes
    "ChurnBucket", "Grindstone", "Hand_Press", "DryingRackLarge", "DryingRackMedium", "Piano",
    "BarricadePlanks", "Pottery_Wheel", "SofteningBeam", "TanninBarrel", "WoodCross", "ButcherHook",
    "ChickenHutch2", "ChickenHutch", "ComposterShoddy", "Composter", "DoubleDoor",
    "Wood_ShelvesDouble_Lvl1", "HeckleComb", "Drying_Rack", "FeedingTroughDouble", "Pottery_Bench",
    "RainCollectorRound", "RainCollectorRound_Tarp", "RainCollector", "RainCollector_Tarp",
    "RippleComb", "ScutchingBoard", "FeedingTroughSimple", "DryingRackSmall", "Herb_Drying_Rack",
    "Wood_BookcaseSmall_Lvl1", "Wood_BookcaseSmall_Lvl2", "Wood_TableSmall_Lvl1",
    "Wood_TableSmall_Lvl2", "Wood_TableSmall_Lvl3", "Spinning_Wheel", "Wood_TableDrawerLvl1",
    "Wood_TableDrawerLvl2", "Wood_TableDrawerLvl3", "Wood_Bed", "Wood_Bookcase_Lvl1",
    "Wood_Bookcase_Lvl2", "Wood_Chair_Lvl1", "Wood_Chair_Lvl2", "Wood_Chair_Lvl3", "Coffin",
    "Wood_BarElement_Lvl1", "Wood_BarElement_Lvl2", "Wood_BarElement_Lvl3",
    "Wood_BarElementCorner_Lvl1", "Wood_BarElementCorner_Lvl2", "Wood_BarElementCorner_Lvl3",
    "Wood_Crate_Lvl1", "Wood_Crate_Lvl2", "WoodenDoorLvl1", "WoodenDoorLvl2", "WoodenDoorLvl3",
    "WoodDoorFrameLvl1", "WoodDoorFrameLvl2", "WoodDoorFrameLvl3", "WoodFenceLvl1", "WoodFenceLvl2",
    "WoodFenceLvl3", "WoodFenceGate", "WoodLampPillar", "WoodFloorLvl1", "WoodFloorLvl2",
    "WoodFloorLvl3", "WoodenPole", "Wood_Shelves_Lvl1", "Wood_Shelves_Lvl2", "WoodSign",
    "Wood_Stairs", "Wood_TableLvl1", "Wood_TableLvl2", "Wood_TableLvl3", "WoodenWallLvl1",
    "WoodenWallLvl2", "WoodenWallLvl3", "WoodenWindowFrameLvl1", "WoodenWindowFrameLvl2",
    "WoodenWindowFrameLvl3", "Wooden_Windows",
    -- crafting recipes
    "MakeShingleMold", "MakeTileMold", "MakeBrickMold", "MakeAdvancedFramepackFrame",
    "MakeAdvancedLargeFramepackFrame", "MakeTrapBox", "MakeWoodenBoxTrap", "MakeLargeBellows",
    "MakeOilPress", "MakeStagHeadTrophy", "MakeWoodenBarCastMold", "MakeWoodenBlacksmithAnvilMold",
    "MakeWoodenBucket", "MakeWoodenCrucibleMold", "MakeWoodenCrudeBenchVisePartsMold",
    "MakeWoodenIngotCastMold", "MakeWoodenShingleMold", "MakeWoodenTileMold", "MakeWoodenToolbox",
}

local function patch()
    local sm = getScriptManager()
    if not sm:getItem(ADD[1]) then return end
    local patched = 0
    for _, id in ipairs(RECIPES) do
        local recipe = sm:getCraftRecipe("Base." .. id)
        local inputs = recipe and recipe:getInputs()
        for i = 0, (inputs and inputs:size() or 0) - 1 do
            local items = inputs:get(i):getItems()
            if items and items:contains(NAIL) then
                for _, add in ipairs(ADD) do
                    if not items:contains(add) then items:add(add) end
                end
                patched = patched + 1
                break
            end
        end
    end
    print("[ZEM] Haiku Primitive bamboo nails patched into " .. patched .. " recipes")
end

pcall(patch)
