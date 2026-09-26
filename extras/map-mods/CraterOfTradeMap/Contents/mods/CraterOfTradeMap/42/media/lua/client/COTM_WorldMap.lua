-- Crater of Trade Map: draws the Crater of Trade painted map (zomboid.wubcord.app) as the
-- in-game world map and minimap, with the game's own street and place names on top.
--
-- The art ships as a B42 image pyramid (media/maps/crateroftrade.pyramid.zip). Areas the art does
-- not cover fall back to the game's own terrain image. Printed/stash maps are left vanilla.
-- Players can switch back to the vanilla map in Options > Mods > Crater of Trade Map.
require "ISUI/Maps/ISMapDefinitions"

local MOD_ID = "CraterOfTradeMap"
local PYRAMID = "crateroftrade.pyramid.zip"

CraterOfTradeMap = CraterOfTradeMap or {}
local ZEM = CraterOfTradeMap

ZEM.options = PZAPI.ModOptions:create(MOD_ID, "Crater of Trade Map")
ZEM.useArt = ZEM.options:addTickBox("useArt", "Use the Crater of Trade map art", true,
    "Draw the painted Crater of Trade map in the world map and minimap (reopen the map to apply).")

local function enabled()
    return not ZEM.useArt or ZEM.useArt:getValue() ~= false
end

-- Absolute paths the pyramid might live at (the engine needs an absolute path; getVersionDir is
-- the mod's "42" folder, getCommonDir its "common" folder).
local candidates = nil
local function pyramidPaths()
    if candidates then return candidates end
    candidates = {}
    local mod = getModInfoByID(MOD_ID)
    if not mod then return candidates end
    local sep = getFileSeparator()
    for _, getter in ipairs({ "getVersionDir", "getCommonDir", "getDir" }) do
        local ok, dir = pcall(function() return mod[getter](mod) end)
        if ok and dir and dir ~= "" then
            candidates[#candidates + 1] = dir .. sep .. "media" .. sep .. "maps" .. sep .. PYRAMID
        end
    end
    return candidates
end

local function applyStyle(mapUI)
    local mapAPI = mapUI.javaObject:getAPIv3()
    mapAPI:setBoolean("ImagePyramid", true)
    for _, path in ipairs(pyramidPaths()) do
        pcall(function() mapAPI:addImagePyramid(path) end)   -- missing files are ignored by the engine
    end
    local styleAPI = mapAPI:getStyleAPI()
    styleAPI:clear()
    -- bottom: the game's own terrain image, so anything outside our art still shows something
    local base = styleAPI:newPyramidLayer("pyramid")
    base:setPyramidFileName("pyramid.zip")
    base:addFill(0.0, 255.0, 255.0, 255.0, 255.0)
    -- our painted map
    local art = styleAPI:newPyramidLayer("crateroftrade")
    art:setPyramidFileName(PYRAMID)
    art:addFill(0.0, 255.0, 255.0, 255.0, 255.0)
    -- top: street names, place names and notes, exactly as vanilla draws them
    MapUtils.initDefaultTextLayersV3(mapUI)
end

local function isPlayerMap(mapUI)
    return type(mapUI) == "table" and (mapUI.Type == "ISWorldMap" or mapUI.Type == "ISMiniMapInner")
end

local vanillaV3 = MapUtils.initDefaultStyleV3
local vanillaV1 = MapUtils.initDefaultStyleV1
local vanillaPaper = MapUtils.overlayPaper

MapUtils.initDefaultStyleV3 = function(mapUI, ...)
    if isPlayerMap(mapUI) and enabled() then return applyStyle(mapUI) end
    return vanillaV3(mapUI, ...)
end

-- the minimap builds its style with V1 (the world map's V3 calls V1 internally, but for the
-- world map our V3 wrapper returns before that happens)
MapUtils.initDefaultStyleV1 = function(mapUI, ...)
    if mapUI and mapUI.Type == "ISMiniMapInner" and enabled() then return applyStyle(mapUI) end
    return vanillaV1(mapUI, ...)
end

-- the paper texture is drawn over everything; skip it on our art
MapUtils.overlayPaper = function(mapUI, ...)
    if isPlayerMap(mapUI) and enabled() then return end
    return vanillaPaper(mapUI, ...)
end
