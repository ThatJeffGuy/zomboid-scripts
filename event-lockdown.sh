#!/usr/bin/env bash
# Lockdown Protocol — Security is high, but the spoils are higher.
#
#   ./event-lockdown.sh
#   ./event-lockdown.sh --end
source "$(dirname "${BASH_SOURCE[0]}")/pz-event-lib.sh"

EVENT_NAME="Lockdown Protocol"
EVENT_HOURS=""
EVENT_END_TIME="4"   # Ends at 4 AM
EVENT_BLURB="<RGB:1,0.8,0.2>Jarvis.. activate lockdown protocol alpha.<LINE><RGB:1,0.3,0.3>Yes sir. Locking every door window and alarms. Be aware that activating lockdown protocol will put those outside at high alert.<LINE><RGB:0.4,1,0.4>High-tier loot inside buildings is doubled, and Sneak, Lightfoot, and Nimble train at 4x XP."

OVERRIDES="
  LockedHouses = 6                    # was 5 (Often) -> 6 (Very Often). See note below.
  Alarm = 6                           # 6 = Very frequent house alarms
  ZombieConfig.FollowSoundDistance = 250 # Alarms pull zeds from huge radius
  RangedWeaponLootNew = 1.8           # was 0.7  high reward inside
  AmmoLootNew = 1.8
  MedicalLootNew = 1.8
  MultiplierConfig.Sneak = 4.0        # was 1.0
  MultiplierConfig.Lightfoot = 4.0    # was 1.0
  MultiplierConfig.Nimble = 4.0       # was 1.0
"

# NOTE: LockedHouses looks to be rolled when a building is first generated,
# so on an explored map this may do very little. Your baseline is already 5
# (Often), so it is a one-step change either way. The alarms and the loot are
# what will actually carry this event.

run_event "$@"