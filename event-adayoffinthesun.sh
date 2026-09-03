#!/usr/bin/env bash
#    A day off for everyone. Does your pop deserve it?
#
#   ./event-adayoffinthesun.sh
#   ./event-adayoffinthesun.sh --end
source "$(dirname "${BASH_SOURCE[0]}")/pz-event-lib.sh"

EVENT_NAME="A Day Off in the Sun"
EVENT_HOURS=24
EVENT_END_TIME=""
EVENT_BLURB="<RGB:0.4,1,0.4>The universe gives Knox County a break today!<LINE><RGB:0.8,1,0.8>Zombies are fragile, blind, and sluggish with zero sprinters on the map. Everything beneficial to a player is doubled.

OVERRIDES="
  StatsDecrease = 5                   # 5 = Very Slow hunger/thirst/fatigue drain
  FoodRotSpeed = 5                    # 5 = Very Slow rot
  FridgeFactor = 6                    # 6 = Off (zero fridge decay)
  NatureAbundance = 5                 # 5 = Very Abundant foraging
  PlantAbundance = 5                  # 5 = Very Abundant farming
  ZombieLore.Toughness = 3            # 3 = Fragile zombies (easier to kill)
  ZombieLore.Sight = 3                # 3 = Poor sight
  ZombieLore.Hearing = 3              # 3 = Poor hearing
  ZombieLore.SprinterPercentage = 0   # Forces 0% sprinters
  FoodLootNew = 2.0                   # Double loot across all tables
  MedicalLootNew = 2.0
  WeaponLootNew = 2.0
  AmmoLootNew = 2.0
  SkillBookLoot = 2.0
  LiteratureLootNew = 2.0
  RecipeResourceLoot = 2.0
  MultiplierConfig.Fitness = 3.0      # Extra boost on top of global 4x
  MultiplierConfig.Strength = 3.0
  MultiplierConfig.Maintenance = 3.0
"

run_event "$@"