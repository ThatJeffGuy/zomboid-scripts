#!/usr/bin/env bash
# ==============================================================================
# Script Name: deploy.sh
# Description: Automates the injection of predefined 'Mods=' and 'WorkshopItems=' 
#              lists into the Project Zomboid server .ini configuration file. 
#              Safely stops the container, creates an .ini backup, updates the 
#              lists, restarts the container, and verifies successful mod loading.
#
# Options:
#   -n, --dry-run  Print out what would happen without stopping the container 
#                  or modifying the .ini file.
# ==============================================================================
set -uo pipefail

INI="/opt/app/zomboid/config/Server/Your_Server_Name.ini"
CONTAINER=zomboid-server
DRY=false
[[ "${1:-}" == "-n" || "${1:-}" == "--dry-run" ]] && DRY=true

MODS=$(cat <<'MODS_EOF'
ETO_B;PROJECTRVInterior42;ChuckleberryFinnAlertSystem;errorMagnifier;tsarslib;MoodleFramework;NeatUI_Framework;ContextMenuIconsCore;daneLibrary;StarlitLibrary;WoodysLib;KATTAJ1_ClothesCore;SWMG;UnifiedCarryWeightFramework;ModManager;ModFolders;AP;FH;SPNCC;SPNCCDetails;SPNCCFaces;HBTacReload;HBVCEFb42;MultipleGeneratorsB42;KAMER_WallHealth;AatheomEMVFSM;AlicesMultiWearVanilla;alicesWeaponSling;alicesWeaponSlingRadialMenu;ATA_Bus;B42PackMule;bdtmre;BetterFlashlightsFixed;BusStopFastTravel;Buttstroke;campintherain;ComputerModkum;CyesPushDoors;DBFaster50;DELRAN_CLICK_TO_WEAR;dustinguished_bolt_cutters;dustinguished_cleaning_wipes;DynamicVehicleSnow;EFTBP;equipwhilerunning;FenceSheets;FunctionalAppliances2;FunctionalGutters;FWOBenchPressTreadmill;FWOFitnessWorkoutOverhaul;GanydeBielovzki's Frockin Shirts n Ties;GanydeBielovzki's Frockin Splendor!;GanydeBielovzki's Frockin Splendor! Vol.2;GanydeBielovzki's Frockin Splendor! Vol.3;GanydeBielovzki's Frockin Splendor! Vol.4;GanydeBielovzki's Frockin Splendor! Vol.5;GanydeBielovzki's Frockin Stompers!;GanydeBielovzki's Frockin Wiseguys;GasPumpIndicator;HandCrankFlashlights;HereGoesTheSun;hf_point_blank;HGOEXP;IMWSEnergyDrinksNEW;KAMER_RepairWall;KATTAJ1_Military;Ladders4220;LongTermPreservationExtended;LongTermPreservationExtendedUI;MoreDamagedObjects;N&CsNarcotics;NepHighBeams;NewMusic;OpenAllContainers;PlayerDogTags42;ProjectArcade;PropaneExchangeCabinet;PSR;RebalancedPropMoving;RepairableWindows;RepairAnyClothes;ResearchLabInternProfession;RetroDashboard;RET_LethalStealth;rSemiTruck;ServingPlates42;SmokingSoundsOverhaul;SomewhatWater;stanks_suicide;Swatpack_by_Slobodskoy;TaillightsAndStoplights;TheOnlyCure;ThisIsYourLife;TLOULevelUpSound;TotalWeightRebalance;Tuna_GunRacks;Tuna_MultiVHS;Tuna_VHS_Collector;VanillaFoodsExpanded;VanillaOutfitsExpanded;VB_CommonSense;Waterpipes;WoodysRainAndWetSnowCleaning;WubcordBus;ZeroWeightKeys_B42;ZVirusVaccine42BETA;MultipleGeneratorsB42Patch;BlackPowderGunsmithing;MarzVanillaGuns;GunsOfMarz;HBAC;SpnHair;SPNRetexture;SPNRetextureUnderwear;SPNRetextureZombie;SPNRetextureZombieUnderwear;FixedLightOnBeltAF;EvolvingTraitsWorld;EvolvingTraitsWorldTraitSandbox;CleanUI;CleanHotBar;Neat_Building;Neat_Building_Railings;Neat_Crafting;Project_Cook;Project_Cook_Pixel_Icon_Pack;TheShortcut;SmarterStorage;P4PickingMeister;P4TidyUpMeister;P4VideoMeister;N3WOMapOverhaul;PZ_Map;AMMS_Standalone;Briefing;B42MoodleDescriptionsExpanded;VHSSkillNameInTooltip;SkillJournal;ExactMinuteClock;CombatText;KillCount;P4HasBeenRead;HideEquippedItems;SwapIt;P4AlarmSyndrome;SimpleContextMenuIcons;NeatUI_Equipment;ProximityInventory;ModLoadOrderSorter_b42
MODS_EOF
)
WS=$(cat <<'WS_EOF'
1299328280;2142622992;2286124931;2366717227;2447729538;2463184726;2544353492;2553809727;2674541310;2699828474;2744797858;2769706949;2847184718;2857762294;2861801557;2896041179;2897115343;2914075159;2940354599;2959854619;2990322197;3002666175;3006882690;3020323164;3042138819;3077900375;3119788162;3290232938;3307376332;3322066592;3340255334;3378285185;3378304610;3389003300;3393821407;3394044313;3396446795;3399320470;3402491515;3402812859;3404956403;3409472393;3409527910;3411888105;3413150945;3414634809;3420478458;3422220305;3423660713;3424309174;3426448380;3429176285;3431256608;3432928943;3437629766;3438126404;3439305933;3453580134;3453676250;3461263912;3465040406;3470422050;3470426196;3470659758;3475347500;3490188370;3492077449;3502080466;3508537032;3531611692;3536052310;3538760023;3540903327;3543229299;3546314080;3565244378;3567084868;3577903007;3580276809;3582960654;3597673472;3600186927;3610677934;3615135168;3615459796;3618557184;3622629134;3629835761;3634921455;3634921763;3635394848;3637364024;3645980077;3671176591;3677588446;3682045254;3687394815;3695167770;3711522956;3715021740;3716522633;3722064198;3722134990;3725311427;3725497089;3736813592;3739256322;3739256725;3750253491;3755185651;3755993986;3763470184;3765409550;3766140920;3766508989;3770149036;3773834525;3773911887;3774820554;3775549570;3776502124;3776641628;3776747895;3778709615;3778884296;3779201168;3780683663;3781818628;3783094058;3784677588;3785033563;3785740658;3786125383;3786155157;3786993262;3788184989;3790656296
WS_EOF
)

[[ -f "$INI" ]] || { echo "no such file: $INI" >&2; exit 1; }
nm=$(tr ';' '\n' <<<"$MODS" | grep -c .)
nw=$(tr ';' '\n' <<<"$WS"   | grep -c .)
echo "Mods entries  : $nm"
echo "WorkshopItems : $nw"
(( nm > 0 && nw > 0 )) || { echo "!! empty list, aborting" >&2; exit 1; }

if [[ "$DRY" == true ]]; then echo "DRY RUN - nothing changed."; exit 0; fi

echo "stopping $CONTAINER ..."
docker stop "$CONTAINER" >/dev/null || { echo "stop failed" >&2; exit 1; }

BACKUP="${INI}.bak.$(date +%Y%m%d-%H%M%S)"
cp -p "$INI" "$BACKUP" && echo "backup: $BACKUP"

TMPF="${INI}.tmp.$$"
awk -v mods="$MODS" -v ws="$WS" '
  /^Mods=/          { print "Mods=" mods; next }
  /^WorkshopItems=/ { print "WorkshopItems=" ws; next }
  { print }
' "$INI" > "$TMPF" || { echo "awk failed, ini untouched" >&2; rm -f "$TMPF"; exit 1; }

grep -q '^Mods=' "$TMPF" && grep -q '^WorkshopItems=' "$TMPF" || {
  echo "!! a key line vanished, ini untouched" >&2; rm -f "$TMPF"; exit 1; }
[[ -s "$TMPF" ]] || { echo "!! empty result, ini untouched" >&2; rm -f "$TMPF"; exit 1; }

cat "$TMPF" > "$INI" && rm -f "$TMPF"
chown 1000:1000 "$INI" 2>/dev/null
echo "ini updated."

docker start "$CONTAINER" >/dev/null || { echo "start failed" >&2; exit 1; }
echo -n "waiting for RCON "
for i in $(seq 1 90); do
  sleep 10
  if docker logs --since 10m "$CONTAINER" 2>&1 | grep -q 'RCON: listening'; then
    echo " up after ~$(( i * 10 ))s"; break
  fi
  printf '.'
done
echo

echo "===== verification ====="
echo -n "mods loaded          : "; docker logs --since 40m "$CONTAINER" 2>&1 | grep -c '> loading '
echo    "  (expected $nm)"
echo -n "ERROR lines          : "; docker logs --since 40m "$CONTAINER" 2>&1 | grep -cE '^[0-9T:.Z-]* *ERROR'
echo "required-mod failures :"
docker logs --since 40m "$CONTAINER" 2>&1 | grep -i 'required mod' | sed 's/^/  /' || true
docker logs --since 40m "$CONTAINER" 2>&1 | grep -qi 'required mod' || echo "  (none)"
echo "first 5 loaded        :"
docker logs --since 40m "$CONTAINER" 2>&1 | grep '> loading ' | sed 's/.*> loading //' | head -5 | sed 's/^/  /'
