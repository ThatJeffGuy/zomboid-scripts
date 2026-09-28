-- Crater of Trade menu branding: in the multiplayer browser (Favorites and the public list), the
-- Crater of Trade server gets its logo banner in the details panel and its round badge in place of
-- the default raccoon icon. It only shows while this mod is enabled in the main-menu Mods list and
-- can be switched off in Options > Mods > Crater of Trade Map. (The main-menu logo is left to the
-- Zomboid Evolved Map mod, so the two mods never fight over it.)
require "COTM_WorldMap"
require "OptionScreens/MultiplayerUI"

local ICON = "media/ui/CraterOfTrade_Icon.png"       -- round badge (optional: raccoon stays until it exists)
local BANNER = "media/ui/CraterOfTrade_Banner.png"   -- 954x251, the vanilla banner's proportions
local CRATER_PORT = "16261"
-- 16261 is the game's default port, so it only counts together with our address.
local CRATER_HOSTS = { ["your.server.example"] = true, ["203.0.113.10"] = true }   -- your server's host name and IP

local COTM = CraterOfTradeMap
local function on(opt) return not opt or opt:getValue() ~= false end

local function isCrater(server)
    if not server then return false end
    local okN, name = pcall(function() return server:getName() end)
    name = okN and tostring(name or ""):lower() or ""
    if name:find("crater of trade") then return true end
    local okP, port = pcall(function() return server:getPort() end)
    local okI, ip = pcall(function() return server:getIp() end)
    return okP and okI and tostring(port) == CRATER_PORT and CRATER_HOSTS[tostring(ip or ""):lower()] == true
end

local iconTex, bannerTex
local function badge() iconTex = iconTex or getTexture(ICON); return iconTex end
local function banner() bannerTex = bannerTex or getTexture(BANNER); return bannerTex end

-- Row painters read their icon from the MultiplayerUI instance (ui_details_icon for Favorites,
-- ui_icon_bg for the public list): swap it in for our row only and put it back afterwards.
local function withBadge(vanilla, field, serverOf)
    return function(self, y, item, alt)
        local root = self.parent and self.parent.parent and self.parent.parent.parent
        if not (root and on(COTM.menuIcon) and isCrater(serverOf(item)) and badge()) then
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

-- Details panel: our banner, and the badge in the big round icon, while the Crater is selected.
local vanillaRender = MultiplayerUI.render
function MultiplayerUI:render()
    if not (on(COTM.menuIcon) and isCrater(self.selectedInternetServer)) then
        return vanillaRender(self)
    end
    local savedBanner, savedIcon = self.default_banner, self.ui_details_icon
    if banner() then self.default_banner = banner() end
    if badge() then self.ui_details_icon = badge() end
    local ok, res = pcall(vanillaRender, self)
    self.default_banner, self.ui_details_icon = savedBanner, savedIcon
    if not ok then error(res) end
    return res
end
