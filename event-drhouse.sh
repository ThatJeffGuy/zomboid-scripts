#!/usr/bin/env bash
#    Did somebody call a doctor? You probably should..
#
#   ./event-biohazard.sh
#   ./event-biohazard.sh --end
source "$(dirname "${BASH_SOURCE[0]}")/pz-event-lib.sh"

EVENT_NAME="Radioactive Fallout Season 3 New Vegas"
EVENT_HOURS=24
EVENT_END_TIME=""
EVENT_BLURB="<RGB:0.2,1,0.6>Some fallout drifted over the Crater of Trade.<LINE><RGB:1,0.4,0.4>Hunger and thirst drain rapidly, and injuries hit harder.<LINE><RGB:0.4,1,0.4>Medical loot spawns everywhere, and First Aid / Doctor skills are at 4x. Pop some Vicodin before you go exploring!"

OVERRIDES="
  StatsDecrease = 1                   # 1 = Very fast hunger/thirst/fatigue
  MedicalLootNew = 2.5                # Heavy medical supplies spawn
  MultiplierConfig.Doctor = 4.0       # was 1.0  (B42 has no separate FirstAid skill)
  MultiplierConfig.Tailoring = 4.0    # was 1.0 for patching armor/clothes
"

run_event "$@"