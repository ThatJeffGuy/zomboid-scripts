#!/usr/bin/env bash
# Whispering Fog — Tread lightly or shoot your way out.
#
#   ./event-whisperingfog.sh
#   ./event-whisperingfog.sh --end
source "$(dirname "${BASH_SOURCE[0]}")/pz-event-lib.sh"

EVENT_NAME="Whispering Fog"
EVENT_HOURS=24
EVENT_END_TIME=""
EVENT_BLURB="<RGB:0.7,0.7,0.9>Jesus Christ.. that's Jason Bourne..<LINE><RGB:0.4,1,0.4>Zombies can barely see, and crouching keeps you invisible. Gunpowder and firearms loot are doubled, with Aiming and Reloading at 4x.<LINE><RGB:1,0.3,0.3>Be careful: the ZIA are after you.. they hear everything.."

OVERRIDES="
  ZombieLore.Sight = 3                # was 2    Poor
  ZombieLore.Hearing = 1              # was 4    Pinpoint
  ZombieLore.Memory = 1               # was 3    Long memory
  RangedWeaponLootNew = 2.0           # was 0.7  guns + attachments
  AmmoLootNew = 2.0                   # was 0.8
  MultiplierConfig.Aiming = 4.0       # was 1.0
  MultiplierConfig.Reloading = 4.0    # was 1.0
  MultiplierConfig.Nimble = 3.0       # was 1.0
"

run_event "$@"