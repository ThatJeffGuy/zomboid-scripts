#!/usr/bin/env bash
#    Blood And Thunder!
#
#   ./event-ironblood.sh
#   ./event-ironblood.sh --end
source "$(dirname "${BASH_SOURCE[0]}")/pz-event-lib.sh"

EVENT_NAME="Blood and Thunder"
EVENT_HOURS=24
EVENT_END_TIME=""
EVENT_BLURB="<RGB:1,0.4,0.2>Guns are useless today, but the steel is sharp!<LINE><RGB:0.4,1,0.4>Melee weapon loot is massively increased, zombies are more fragile, and all melee combat skills + Maintenance gain 4x XP.<LINE><RGB:1,0.3,0.3>Firearms and ammunition have stopped spawning entirely. Get up close and personal."

OVERRIDES="
  RangedWeaponLootNew = 0.05          # was 0.7  guns+attachments virtually removed
  AmmoLootNew = 0.05                  # Ammo virtually removed
  WeaponLootNew = 2.5                 # was 0.8  this IS the melee category
  ZombieLore.Toughness = 3            # 3 = Fragile zombies
  MultiplierConfig.Axe = 4.0          # was 1.0
  MultiplierConfig.Blunt = 4.0        # was 1.0
  MultiplierConfig.SmallBlunt = 4.0   # was 1.0
  MultiplierConfig.LongBlade = 4.0    # was 1.0
  MultiplierConfig.SmallBlade = 4.0   # was 1.0
  MultiplierConfig.Spear = 4.0        # was 1.0   (key is Spear, not LongSpear)
  MultiplierConfig.Maintenance = 4.0  # was 1.0
"

run_event "$@"