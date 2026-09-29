-- Zomboid Evolved menu branding: puts the Zomboid Evolved badge on the server's row in the
-- multiplayer browser (Favorites and the public list) and in its details panel (with a strip of the
-- painted map as the banner). It only shows while this mod is enabled in the main-menu Mods list,
-- and can be switched off in Options > Mods > Zomboid Evolved Core. The main-menu Project Zomboid logo
-- is left alone (the user's call, 2026-09-28).
require "ZEM_WorldMap"
require "OptionScreens/MultiplayerUI"

local ICON = "media/ui/ZomboidEvolved_Icon.png"
local BANNER = "media/ui/ZomboidEvolved_Banner.png"   -- 954x251, the vanilla banner's proportions
local EVOLVED_PORT = "16263"          -- the Zomboid Evolved server's game port

local ZEM = ZomboidEvolvedMap
local function on(opt) return not opt or opt:getValue() ~= false end

-- Favorites keep whatever name the player typed, so match the usual names or the server's port.
local function isEvolved(server)
    if not server then return false end
    local okN, name = pcall(function() return server:getName() end)
    name = okN and tostring(name or ""):lower() or ""
    if name:find("zomboid evolved") or name:find("project evolution") then return true end
    local okP, port = pcall(function() return server:getPort() end)
    return okP and tostring(port) == EVOLVED_PORT
end

local iconTex
local function badge()
    iconTex = iconTex or getTexture(ICON)
    return iconTex
end

-- Both row painters read their icon from the MultiplayerUI instance (ui_details_icon for Favorites,
-- ui_icon_bg for the public list), so swap it in for our row only and put it back afterwards.
local function withBadge(vanilla, field, serverOf)
    return function(self, y, item, alt)
        local root = self.parent and self.parent.parent and self.parent.parent.parent
        local server = serverOf(item)
        if not (root and on(ZEM.menuIcon) and isEvolved(server) and badge()) then
            return vanilla(self, y, item, alt)
        end
        local saved = root[field]
        root[field] = badge()
        local ok, res = pcall(vanilla, self, y, item, alt)
        root[field] = saved
        if not ok then error(res) end
        return res
    end
end

MultiplayerUI.drawAccountListItem = withBadge(MultiplayerUI.drawAccountListItem, "ui_details_icon", function(item)
    return item and item.item and item.item.type == "server" and item.item.server or nil
end)
MultiplayerUI.drawInternetListItem = withBadge(MultiplayerUI.drawInternetListItem, "ui_icon_bg", function(item)
    return item and item.item or nil
end)

-- Details panel: while our server is selected, its banner strip becomes painted-map art and the big
-- round icon (the raccoon) becomes the badge.
local bannerTex
local vanillaRender = MultiplayerUI.render
function MultiplayerUI:render()
    if not (on(ZEM.menuIcon) and isEvolved(self.selectedInternetServer) and badge()) then
        return vanillaRender(self)
    end
    bannerTex = bannerTex or getTexture(BANNER)
    local savedBanner, savedIcon = self.default_banner, self.ui_details_icon
    if bannerTex then self.default_banner = bannerTex end
    self.ui_details_icon = badge()
    local ok, res = pcall(vanillaRender, self)
    self.default_banner, self.ui_details_icon = savedBanner, savedIcon
    if not ok then error(res) end
    return res
end
