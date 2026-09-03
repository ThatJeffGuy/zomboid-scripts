#!/usr/bin/env bash
#   The Long Night — like the long walk but.. darker..
#
#   ./event-longnight.sh          start it
#   ./event-longnight.sh --end    end it, back to baseline
source "$(dirname "${BASH_SOURCE[0]}")/pz-event-lib.sh"

EVENT_NAME="The Long Night"
EVENT_HOURS=          # length, if EVENT_END_TIME is empty
EVENT_END_TIME="4"       # or an hour 1-24 (e.g. 4 = next 4am) to end at a fixed time
EVENT_BLURB="<RGB:0.6,0.6,1>The sun did not come up today.<RGB:0.4,1,0.4>The dead cannot see or hear well, but most light soruces are buffed.<LINE><RGB:1,0.9,0.5>Sneaking, Lightfooted and Nimble all train at 4x.<LINE><RGB:1,0.5,0.5>Nobody sleeps, but all those light sources should last longer. Zeds aren't afraid of the dark.. Good luck."

OVERRIDES="
  NightLength = 1                    # was 3    1 = Always Night (4 = Short!)
  NightDarkness = 1                  # was 3    Dark, NOT Pitch Black
  ZombieLore.Sight = 1               # was 2    Poor
  ZombieLore.Hearing = 1             # was 4    Poor, instead of full Random
  Alarm = 2                          # was 4    Extremely Rare
  Helicopter = 1                     # was 2    Never
  LightBulbLifespan = 8.0            # was 2.0
  BFFloorLights.radiusMult = 0.6     # was 0.25 wider flashlight pool
  HandCrankFlashlights.LightDistance = 25   # was 15
  HandCrankFlashlights.ConditionLoseRate = 10  # was 25
  MultiplierConfig.Sneak = 4.0       # was 1.0
  MultiplierConfig.Lightfoot = 4.0   # was 1.0
  MultiplierConfig.Nimble = 4.0      # was 1.0
"

INI_START="SleepAllowed=false"
INI_END="SleepAllowed=true"

run_event "$@"
