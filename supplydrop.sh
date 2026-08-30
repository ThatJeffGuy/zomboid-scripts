# ==============================================================================
# Script Name: supplydrop.sh
# Description: Distributes randomized, weighted loot (supply drops) to connected 
#              players via RCON. Includes cooldown management, broadcasts 
#              immersive server announcements, and reads from a weighted pool file.
#
# Options:
#   --dry-run             Simulate the roll and drop process without giving items
#                         or updating the cooldown state file.
#   --odds <N>            Run a statistical simulation of N rolls (default 1000) 
#                         to test item weight distributions. Exits after printing.
#   --verify <PlayerName> Spawns exactly 1 of EVERY item in the pool file into 
#                         the target player's inventory to verify valid item IDs.
# ==============================================================================
#!/usr/bin/env bash

set -uo pipefail

RCON=rcon
POOL=/root/pz-pool.txt
LOG=/root/pz-supplydrop.log
LOG_KEEP_HOURS=48
MAX_ITEMS=3
DELAY=1
ANNOUNCE=1
ANNOUNCE_ITEMS=0

ANNOUNCE_MESSAGES=(
  "A plane is seen smoking and shedding parts. You race to grab the items that fell nearby."
  "An old military drone sputters past, jettisoning parts across the region!"
  "A sonic boom shakes the ground as a large bomb goes off in the distance. You feel some debris hit your back."
  "Static crackles on the radio... emergency supplies have been deployed overhead!"
  "A parachuted crate descends through the tree line nearby detonating on impact, throwing junk everywhere."
)

pzrcon() { command "$RCON" "$1" 2>&1; }
log()    { echo "$(date '+%F %T') $*"; }

trim_log() {
  [[ -f "$LOG" && -w "$LOG" ]] || return 0
  local cutoff
  cutoff="$(date -d "$LOG_KEEP_HOURS hours ago" '+%F %T')" || return 0
  awk -v cutoff="$cutoff" '
    { ts = substr($0, 1, 19) }
    ts ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ {
      keep = ((ts "") >= (cutoff ""))
    }
    keep
  ' "$LOG" > "${LOG}.tmp" 2>/dev/null || { rm -f "${LOG}.tmp"; return 0; }
  cat "${LOG}.tmp" > "$LOG"
  rm -f "${LOG}.tmp"
}

DRY=0; VERIFY=""; ODDS=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  --odds)    ODDS="${2:-1000}" ;;
  --verify)  VERIFY="${2:-}"; [[ -z "$VERIFY" ]] && { echo "--verify needs a player name"; exit 1; } ;;
  "") ;;
  *) echo "Usage: $0 [--dry-run | --odds N | --verify PlayerName]"; exit 1 ;;
esac

trim_log

[[ -r "$POOL" ]] || { log "Pool file not readable: $POOL" >&2; exit 1; }
mapfile -t ITEMS < <(grep -v '^[[:space:]]*#' "$POOL" | grep -v '^[[:space:]]*$')
[[ ${#ITEMS[@]} -gt 0 ]] || { log "Pool is empty: $POOL" >&2; exit 1; }

roll() {
  local n="$1"
  printf '%s\n' "${ITEMS[@]}" | awk -v n="$n" -v seed="$RANDOM$$" '
    BEGIN { srand(seed) }
    {
      if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next
      split($0, a, "|")
      if (length(a[1]) == 0) next
      
      gsub(/[^0-9]/, "", a[3])
      w = a[3] + 0
      if (w <= 0) w = 1
      
      u = rand()
      if (u <= 0) u = 1e-9
      
      key = -log(u) / w
      
      printf "%018.9f\t%s\t%s\n", key, a[1], a[2]
    }' | sort -k1,1n | awk -F'\t' -v n="$n" '
    BEGIN { count = 0 }
    {
      if ($2 != "" && !seen[$2]++) {
        print $2 "\t" $3
        count++
        if (count >= n) exit
      }
    }'
}

if [[ "$ODDS" -gt 0 ]]; then
  echo "Simulating $ODDS single-item rolls..."
  printf '%s\n' "${ITEMS[@]}" | awk -v iterations="$ODDS" -v seed="$RANDOM$$" '
    BEGIN {
      srand(seed)
    }
    {
      if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next
      split($0, a, "|")
      if (length(a[1]) == 0) next
      
      gsub(/[^0-9]/, "", a[3])
      w = a[3] + 0
      if (w <= 0) w = 1
      
      id[count] = a[1]
      weight[count] = w
      count++
    }
    END {
      for (i = 0; i < iterations; i++) {
        min_val = 999999999
        winning_id = ""
        for (j = 0; j < count; j++) {
          u = rand()
          if (u <= 0) u = 1e-9
          val = -log(u) / weight[j]
          if (val < min_val) {
            min_val = val
            winning_id = id[j]
          }
        }
        if (winning_id != "") counts[winning_id]++
      }
      for (k in counts) {
        printf "%7d %s\n", counts[k], k
      }
    }' | sort -rn | head -25
  exit 0
fi

if [[ -n "$VERIFY" ]]; then
  log "Verifying ${#ITEMS[@]} item IDs against $VERIFY — this will flood their inventory"
  bad=0
  for entry in "${ITEMS[@]}"; do
    id="${entry%%|*}"
    out="$(pzrcon "additem \"$VERIFY\" \"$id\" 1")"
    grep -qiE 'unknown|error|invalid|no such|not found' <<<"$out" && { echo "  BAD  $id"; bad=$((bad+1)); }
    sleep "$DELAY"
  done
  log "Done. $bad bad ID(s) of ${#ITEMS[@]}."
  exit 0
fi

STATE=/root/.pz-supplydrop-next
MIN_HOURS=2
MAX_HOURS=6

schedule_next() {
  local span=$(( (MAX_HOURS - MIN_HOURS) * 3600 ))
  local r=$(( $(od -An -N4 -tu4 </dev/urandom | tr -d ' ') % span ))
  local next=$(( $(date +%s) + MIN_HOURS * 3600 + r ))
  echo "$next" > "$STATE"
  log "Next drop window opens $(date -d "@$next" '+%F %T')"
}

if [[ $DRY -eq 0 && -z "$VERIFY" ]]; then
  now=$(date +%s)
  if [[ -r "$STATE" ]]; then
    next="$(<"$STATE")"
    if (( now < next )); then
      log "Cooldown active until $(date -d "@$next" '+%F %T') — skipping."
      exit 0
    fi
  else
    log "No state file — seeding schedule, no drop this run."
    schedule_next
    exit 0
  fi
fi

raw="$(pzrcon 'players')"
[[ -z "$raw" ]] && { log "RCON returned nothing — is the server up?"; exit 1; }

mapfile -t PLAYERS < <(printf '%s\n' "$raw" | grep -E '^[[:space:]]*-' | sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/[[:space:]]*$//')

if [[ ${#PLAYERS[@]} -eq 0 ]]; then log "No players connected — no drop."; exit 0; fi

log "Supply drop for ${#PLAYERS[@]} player(s): ${PLAYERS[*]}  (pool: ${#ITEMS[@]})"
[[ $DRY -eq 1 ]] && log "*** DRY RUN ***"

if [[ $DRY -eq 0 && $ANNOUNCE -eq 1 ]]; then
  msg_idx=$(( RANDOM % ${#ANNOUNCE_MESSAGES[@]} ))
  selected_msg="${ANNOUNCE_MESSAGES[$msg_idx]}"

  log "Broadcasting drop event: \"$selected_msg\""
  pzrcon "servermsg \"$selected_msg\"" >/dev/null
  sleep 1
fi

delivered_count=0
failed_count=0

for p in "${PLAYERS[@]}"; do
  n=$(( RANDOM % MAX_ITEMS + 1 ))
  names=()
  player_failed=0

  while IFS=$'\t' read -r id disp; do
    [[ -z "$id" ]] && continue
    names+=("${disp:-$id}")
    if [[ $DRY -eq 1 ]]; then echo "  would send: additem \"$p\" \"$id\" 1"; continue; fi
    out="$(pzrcon "additem \"$p\" \"$id\" 1")"
    if grep -qiE 'unknown|error|invalid|no such|not found' <<<"$out"; then
      log "  BAD ID  $p <- $id : $out"
      player_failed=$((player_failed + 1))
      failed_count=$((failed_count + 1))
    else
      delivered_count=$((delivered_count + 1))
    fi
    sleep "$DELAY"
  done < <(roll "$n")

  if [[ ${#names[@]} -gt 0 && $player_failed -lt ${#names[@]} ]]; then
    joined="$(printf '%s, ' "${names[@]}")"; joined="${joined%, }"
    log "  $p <- $joined"
    if [[ $DRY -eq 0 && $ANNOUNCE_ITEMS -eq 1 ]]; then
      pzrcon "servermsg \"${p} received: ${joined}\"" >/dev/null
      sleep 0.5
    fi
  else
    log "  $p <- nothing delivered"
  fi
done

log "Drop complete: $delivered_count delivered, $failed_count failed."

[[ $DRY -eq 0 ]] && schedule_next
