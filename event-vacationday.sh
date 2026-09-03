#!/usr/bin/env bash
#    Vacation Day
#
#   ./event-miracle.sh
#   ./event-miracle.sh --end
source "$(dirname "${BASH_SOURCE[0]}")/pz-event-lib.sh"

EVENT_NAME="Miracle Day"
EVENT_HOURS=24
EVENT_END_TIME=""
EVENT_BLURB="<RGB:0.4,1,0.4>The universe gives Knox County a break today!<LINE><RGB:0.8,1,0.8>Zombies are fragile, blind, and sluggish with zero sprinters on the map. Hunger, thirst, and fatigue drain at a crawl, and food in the fridge never rots.<LINE><RGB:0.4,0.8,1>Loot spawns across every single category are doubled, and physical stats train at accelerated rates. Take a breath and catch up!"

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