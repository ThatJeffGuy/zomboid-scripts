#!/usr/bin/env bash
#   Muckbang Central lads.. watch out for splatter..
#
#   ./event-fatfuck.sh          start it
#   ./event-fatfuck.sh --end    end it, back to baseline
#   ./event-fatfuck.sh --dry    show the diff, change nothing
source "$(dirname "${BASH_SOURCE[0]}")/pz-event-lib.sh"

EVENT_NAME="Fat Fuck Friday"
EVENT_HOURS=          # length, if EVENT_END_TIME is empty
EVENT_END_TIME="4"       # or an hour 1-24 (e.g. 4 = next 4am) to end at a fixed time
EVENT_BLURB="<RGB:0.4,1,0.4>Ughh.. why are you so fat? I know why.. Plants harvest at 4x and food in the fridge seemingly never expires.<LINE><RGB:1,0.3,0.3>You are always starving you fatty. So are they. More of them run now, they hear you from much further off, and they do not forget that you have chips in your pockets. Good luck!"

OVERRIDES="
  Farming = 1                             # was 3   Very Fast
  PlantAbundance = 5                      # was 3   Very Abundant
  PlantResilience = 1                     # was 3   Very High
  NatureAbundance = 5                     # was 3   foraging
  FoodRotSpeed = 5                        # was 3   Very Slow
  FridgeFactor = 6                        # was 3   No decay
  FoodLootNew = 1.6                       # was 0.8
  CookwareLootNew = 1.4                   # was 0.8
  StatsDecrease = 1                       # was 3   hunger hits fast
  MultiplierConfig.Cooking = 2.0          # was 1.0 on top of 4x Global
  MultiplierConfig.Farming = 2.0          # was 1.0
  ZombieLore.SprinterPercentage = 15      # was 3   Speed stays Random
  ZombieLore.Hearing = 1                  # was 4   Pinpoint
  ZombieLore.Memory = 1                   # was 3   Long
  ZombieConfig.FollowSoundDistance = 200  # was 75
"

run_event "$@"
