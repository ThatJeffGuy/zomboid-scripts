#!/usr/bin/env bash
# 28 Seconds Later — They're fast, but stupid, just like twitch chat.
#
#   ./event-28seconds.sh
#   ./event-28seconds.sh --end
source "$(dirname "${BASH_SOURCE[0]}")/pz-event-lib.sh"

EVENT_NAME="28 Seconds Later"
EVENT_HOURS=""
EVENT_END_TIME="4"   # Ends at 4 AM
EVENT_BLURB="<RGB:1,0.2,0.2>Rule 2: Cardio.<LINE><RGB:0.4,1,0.4>All physical and combat skills gain 4x XP, but sprinters are at 100%"

OVERRIDES="
  ZombieLore.Speed = 1                # 1 = Sprinters (forces 100% sprinters)
  ZombieLore.Sight = 3                # was 2    Poor sight
  ZombieLore.Memory = 3               # baseline is already 3 - no-op, kept for clarity
  ZombieLore.Hearing = 3              # was 4    Poor hearing
  AmmoLootNew = 2.0                   # was 0.8
  MedicalLootNew = 2.0                # was 0.8
  MultiplierConfig.Fitness = 4.0      # was 1.0
  MultiplierConfig.Sprinting = 4.0    # was 1.0
  MultiplierConfig.Axe = 4.0          # was 1.0
  MultiplierConfig.Blunt = 4.0        # was 1.0
  MultiplierConfig.SmallBlunt = 4.0   # was 1.0
  MultiplierConfig.Spear = 4.0        # was 1.0   (key is Spear, not LongSpear)
"

run_event "$@"