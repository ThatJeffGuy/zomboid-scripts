#!/usr/bin/env bash
#    For The Horde! No, not that horde..
#
#   ./event-ironblood.sh
#   ./event-ironblood.sh --end
source "$(dirname "${BASH_SOURCE[0]}")/pz-event-lib.sh"

EVENT_NAME="Blood and Thunder"
EVENT_HOURS=24
EVENT_END_TIME=""
EVENT_BLURB="<RGB:1,0.4,0.2>Guns are never the answer.<LINE><RGB:0.4,1,0.4>Melee weapon loot is massively increased, zombies are more fragile, and all melee combat skills + Maintenance gain 4x XP.<LINE><RGB:1,0.3,0.3>Firearms and ammunition have stopped spawning entirely, and current ones wear out at 4x. Get up close and personal today!"

OVERRIDES="
  FirearmJamMultiplier = 10.0        # was 1.0  max - jams constantly
  FirearmUseDamageChance = 3         # was 2    degrades on every target
  FirearmMoodleMultiplier = 10.0     # was 1.0  panic/tired wreck accuracy
  FirearmWeatherMultiplier = 10.0    # was 1.0  wind and rain wreck it too
  FirearmNoiseMultiplier = 2.0       # was 1.0  max - shots pull the whole town
  RangedWeaponLootNew = 0.0          # was 0.7  no guns spawning
  AmmoLootNew = 0.0                  # was 0.8  no ammo spawning
  MultiplierConfig.Aiming = 0.25     # was 1.0
  MultiplierConfig.Reloading = 0.25  # was 1.0
  WeaponLootNew = 2.0                # was 0.8  this IS the melee category
  MultiplierConfig.Maintenance = 4.0 # was 1.0  offsets breakage
  MultiplierConfig.Axe = 4.0         # was 1.0
  MultiplierConfig.Blunt = 4.0       # was 1.0
  MultiplierConfig.SmallBlunt = 4.0  # was 1.0
  MultiplierConfig.LongBlade = 4.0   # was 1.0
  MultiplierConfig.SmallBlade = 4.0  # was 1.0
  MultiplierConfig.Spear = 4.0       # was 1.0
  MultiplierConfig.Sneak = 4.0       # was 1.0
  MultiplierConfig.Lightfoot = 4.0   # was 1.0
  MultiplierConfig.Nimble = 4.0      # was 1.0
  ZombieLore.Sight = 3               # was 2    Poor - crouching works
  ZombieLore.Hearing = 1             # was 4    Pinpoint - noise punishes hard
"

run_event "$@"