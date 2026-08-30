#!/usr/bin/env bash
# pz-genmods.sh v2 — build a load-ordered Mods= line from downloaded Workshop mods.
#
# v2 changes:
#   * Only reads Workshop IDs listed in ALLOW (your WorkshopItems= line), so
#     leftover mods from previous installs are ignored.
#   * Strips any "<workshopid>/" prefix from nested mod ids.
#   * Reports Workshop items that ship MORE THAN ONE mod, so you can choose
#     which variant to keep instead of enabling all of them.
#
#   docker exec -i zomboid-server bash -s < pz-genmods.sh
#   docker exec -i zomboid-server bash -s < pz-genmods.sh 2>/dev/null   # line only

set -uo pipefail

CONTENT="${1:-/project-zomboid/steamapps/workshop/content/108600}"
[[ -d "$CONTENT" ]] || { echo "No such directory: $CONTENT" >&2; exit 1; }

# ---- allowlist: exactly the WorkshopItems= line -----------------------------
ALLOW="
    1299328280 2142622992 2286124931 2366717227 2447729538 2463184726 2544353492 2553809727
    2674541310 2699828474 2744797858 2769706949 2847184718 2857762294 2861801557 2896041179
    2897115343 2914075159 2940354599 2959854619 2990322197 3002666175 3006882690 3020323164
    3042138819 3077900375 3119788162 3290232938 3307376332 3322066592 3340255334 3378285185
    3378304610 3389003300 3393821407 3394044313 3396446795 3399320470 3402491515 3402812859
    3404956403 3409472393 3409527910 3411888105 3413150945 3414634809 3420478458 3422220305
    3423660713 3424309174 3426448380 3429176285 3431256608 3432928943 3437629766 3438126404
    3439305933 3453580134 3453676250 3461263912 3465040406 3470422050 3470426196 3470659758
    3475347500 3490188370 3492077449 3502080466 3508537032 3531611692 3536052310 3538760023
    3540903327 3543229299 3546314080 3565244378 3567084868 3577903007 3580276809 3582960654
    3597673472 3600186927 3610677934 3615135168 3615459796 3618557184 3622629134 3629835761
    3634921455 3634921763 3635394848 3637364024 3645980077 3671176591 3677588446 3682045254
    3687394815 3695167770 3711522956 3715021740 3716522633 3722064198 3722134990 3725311427
    3725497089 3736813592 3739256322 3739256725 3750253491 3755185651 3755993986 3763470184
    3765409550 3766140920 3766508989 3770149036 3773834525 3773911887 3774820554 3775549570
    3776502124 3776641628 3776747895 3778709615 3778884296 3779201168 3780683663 3781818628
    3783094058 3784677588 3785033563 3785740658 3786125383 3786155157 3786993262 3788184989
    3790656296"

# ---- tier 0: loads first (texture pass, then libraries and frameworks) ------
T0="3119788162 3543229299 3077900375 2896041179 3402491515 3396446795 3508537032
    3634921455 3715021740 3378285185 3622629134 3470422050 3722064198
    3682045254 3567084868 3779201168 3766508989 2447729538 3414634809
    3610677934 3695167770 3002666175"

# ---- tier 2: must load AFTER their base mod --------------------------------
T2="3786125383 3766140920 3773834525 3722134990 3637364024 2463184726
    3340255334 3778709615 2914075159"

# ---- tier 3: UI overrides, late --------------------------------------------
T3="3437629766 3461263912 3536052310 3502080466 3490188370 3470659758
    3290232938 3422220305 2769706949 2744797858 3785033563 3770149036 3020323164 3565244378 3389003300
    3716522633 3776641628 3778884296 2286124931 2553809727
    2544353492 3600186927 2366717227 3409527910 3634921763 3790656296
    2847184718"

# ---- tier 4: absolute last -------------------------------------------------
T4="3423660713"

# ---- mod ids to EXCLUDE (variant losers, duplicates, author-disabled) ------
DENY="ETO_P IMWSEnergyDrinks IMWSEnergyDrinksBETA ToadTraits ToadTraitsDynamic
      ToadTraitsDisablePrepared ToadTraitsDisableSpec DBFaster25 DBFaster60
      DBFaster70 DBFaster80 Ladders42131 SomewhatWaterBright
      FunctionalGuttersRemoved WaterpipesRemoved Neat_Building_UIOnly
      Neat_Building_Buildables_SESCompat SPNCCDetailsHD SPNRetextureCustom
      zHBVCEF MarzGuns ModernStatus CHStatusHUD
      RainCleansBlood DetailedDescriptionsForOccupationsAndTraits Project_Seasons_B41 Project_Seasons_B41_LITE
      Project_Seasons_B42 Project_Seasons_B42_LITE Project_Seasons_B42_NORUST
      Siowar_distiller Siowar_distiller_easy PompCollectibles UsefulBarrelsMP"

# Ids containing spaces need their own list (word-splitting would break them).
DENY_EXACT=(
  "Buttstroke 42.12.3"
  "GanydeBielovzki's Frockin Stompers! VFR"
  "Run and Reload"
)

denied() {
  local id="$1" x
  for x in $DENY; do [[ "$x" == "$id" ]] && return 0; done
  for x in "${DENY_EXACT[@]}"; do [[ "$x" == "$id" ]] && return 0; done
  return 1
}

pos_in() {
  local id="$1" set="$2" i=0 x
  for x in $set; do
    [[ "$x" == "$id" ]] && { echo "$i"; return 0; }
    i=$(( i + 1 ))
  done
  return 1
}

TMP="$(mktemp)"; MULTI="$(mktemp)"
trap 'rm -f "$TMP" "$MULTI"' EXIT

found=0 skipped=0 missing=0 allowed=0 denied_n=0
for wsdir in "$CONTENT"/*/; do
  wsid="$(basename "$wsdir")"
  [[ "$wsid" =~ ^[0-9]+$ ]] || continue

  if ! pos_in "$wsid" "$ALLOW" >/dev/null; then
    skipped=$(( skipped + 1 ))
    continue
  fi
  allowed=$(( allowed + 1 ))

  mapfile -t infos < <(find "$wsdir" -maxdepth 4 -name mod.info -type f 2>/dev/null)
  if (( ${#infos[@]} == 0 )); then
    echo "  !! no mod.info under $wsid" >&2
    missing=$(( missing + 1 ))
    continue
  fi

  if   rank="$(pos_in "$wsid" "$T0")"; then tier=0
  elif rank="$(pos_in "$wsid" "$T4")"; then tier=4
  elif rank="$(pos_in "$wsid" "$T2")"; then tier=2
  elif rank="$(pos_in "$wsid" "$T3")"; then tier=3
  else tier=1; rank=0
  fi

  n_here=0
  ids_here=""
  for f in "${infos[@]}"; do
    modid="$(grep -m1 -i '^id=' "$f" | cut -d= -f2- | tr -d '\r' \
             | sed 's#^[[:space:]]*##; s#[[:space:]]*$##; s#^[0-9]\{6,\}/##')"
    [[ -n "$modid" ]] || continue
    if denied "$modid"; then
      printf '  -- excluded: %s (from %s)\n' "$modid" "$wsid" >&2
      denied_n=$(( denied_n + 1 ))
      continue
    fi
    grep -qxF "$modid" <<<"$ids_here" && continue
    ids_here+="$modid"$'\n'
    printf '%d\t%04d\t%s\t%s\n' "$tier" "$rank" "$modid" "$wsid" >>"$TMP"
    found=$(( found + 1 ))
    n_here=$(( n_here + 1 ))
  done
  if (( n_here > 1 )); then
    printf '%s\t%s\n' "$wsid" "$(tr '\n' ' ' <<<"$ids_here")" >>"$MULTI"
  fi
done

{
  awk -F'\t' '$1==0' "$TMP" | sort -t$'\t' -k2,2 | cut -f3
  awk -F'\t' '$1==1' "$TMP" | cut -f3 | sort -f
  awk -F'\t' '$1==2' "$TMP" | sort -t$'\t' -k2,2 | cut -f3
  awk -F'\t' '$1==3' "$TMP" | sort -t$'\t' -k2,2 | cut -f3
  awk -F'\t' '$1==4' "$TMP" | cut -f3
} | awk '!seen[$0]++' > "${TMP}.ord"

{
  echo
  echo "allowlist entries : $(pos_in _ "$ALLOW" >/dev/null; echo $(wc -w <<<"$ALLOW"))"
  echo "matched on disk   : $allowed"
  echo "skipped (not in allowlist) : $skipped"
  echo "no mod.info       : $missing"
  echo "excluded by DENY  : $denied_n"
  echo "mod ids collected : $found  (unique: $(wc -l < "${TMP}.ord"))"
  if [[ -s "$MULTI" ]]; then
    echo
    echo "### Workshop items shipping MORE THAN ONE mod — review these:"
    while IFS=$'\t' read -r w m; do printf '  %s : %s\n' "$w" "$m"; done <"$MULTI"
    echo "### Enabling every variant of these can conflict. Keep one where the mod says so."
  fi
  echo
} >&2

printf 'Mods='
paste -sd';' "${TMP}.ord"
rm -f "${TMP}.ord"