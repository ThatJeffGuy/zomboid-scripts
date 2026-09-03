#!/usr/bin/env bash
#    Gone Campin' event.
#
#   ./event-wilderness.sh
#   ./event-wilderness.sh --end
source "$(dirname "${BASH_SOURCE[0]}")/pz-event-lib.sh"

EVENT_NAME="Gone Camping"
EVENT_HOURS=24
EVENT_END_TIME=""
EVENT_BLURB="<RGB:0.4,1,0.4>Time to get out there and touch grass!<LINE><RGB:0.8,1,0.8>Foraging, Trapping, Fishing, and Cooking gain 4x XP.<LINE><RGB:1,0.9,0.5>Zombies are also wanting to go camping, so they will be seen farther out today and in groups more often"

OVERRIDES="
  PlantAbundance = 5                  # 5 = Very Abundant
  NatureAbundance = 5                 # 5 = Very Abundant
  MultiplierConfig.PlantScavenging = 4.0 # was 1.0  (B42 renamed Foraging)
  MultiplierConfig.Trapping = 4.0     # was 1.0
  MultiplierConfig.Fishing = 4.0      # was 1.0
  MultiplierConfig.Cooking = 4.0      # was 1.0
  ZombieConfig.RallyTravelDistance = 50 # was 10  they gather from further out
  ZombieConfig.RallyGroupSize = 25      # was 10  and into bigger packs
"

run_event "$@"