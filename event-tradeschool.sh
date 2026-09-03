#!/usr/bin/env bash
# Trade school — B42 crafting skills only. Global XP is already 4x, so this
# uses per-skill multipliers; raising Global further stops feeling like anything.
#
#   ./event-tradeschool.sh          start it
#   ./event-tradeschool.sh --end    end it, back to baseline
source "$(dirname "${BASH_SOURCE[0]}")/pz-event-lib.sh"

EVENT_NAME="Trade School"
EVENT_HOURS=24          # length, if EVENT_END_TIME is empty
EVENT_END_TIME=""       # or an hour 1-24 (e.g. 4 = next 4am) to end at a fixed time
EVENT_BLURB="<RGB:1,0.9,0.5>You awake feeling extra absorbent for knowledge. All those complicated books now seemly read like a Fox News article -- super easy!<LINE><RGB:0.8,1,0.8>Skill books and reading material are far more common while it lasts. But those Zeds are looking to take your lunch money. They all have weapons equipped and armor, and they can all open doors and windows. Sprinters? You're lucky they're at an away game today.."

OVERRIDES="
  MultiplierConfig.Woodwork = 3.0     # was 1.0
  MultiplierConfig.MetalWelding = 3.0 # was 1.0
  MultiplierConfig.Blacksmith = 3.0   # was 1.0
  MultiplierConfig.Masonry = 3.0      # was 1.0
  MultiplierConfig.Pottery = 3.0      # was 1.0
  MultiplierConfig.Carving = 3.0      # was 1.0
  MultiplierConfig.Glassmaking = 3.0  # was 1.0
  MultiplierConfig.Tailoring = 3.0    # was 1.0
  MultiplierConfig.FlintKnapping = 3.0 # was 1.0
  SkillBookLoot = 1.6                 # was 0.7
  LiteratureLootNew = 1.6             # was 0.8
  RecipeResourceLoot = 1.4            # was 0.8
  ZombieLore.DoorOpeningPercentage = 100  # was 5   all of them work door handles
  ZombieLore.SprinterPercentage = 0       # was 3   no sprinters today
"

run_event "$@"
