#!/bin/bash
# ==============================================================================
# NEW CHARACTER KIT  (added 2026-09-26)
# ==============================================================================
# Watches the server PerkLog for "[Created Player N]" (logged for every new
# character: first join AND respawn after death):
#   - SteamID never seen on this world -> NEW PLAYER drop: full new-player kit to them,
#     an MRE (only) to everyone else online; the SteamID is recorded
#   - SteamID already seen (death)     -> RESPAWN kit to that player only
# Offline players never get anything later (no queue). Each drop sends one random
# line from ANNOUNCE_MESSAGES in supplydrop.sh (read at run time, so edits to those
# broadcasts apply here too; supplydrop.sh itself is never run).
# Requires PerkLogs=true in the server ini. Run from cron every minute.
#
# Usage: newplayer-kit.sh                     normal cron run
#        newplayer-kit.sh --dry-run           show what would be given, change nothing
#        newplayer-kit.sh --seed              record every SteamID in the player DB as seen
#        newplayer-kit.sh --reset             forget all SteamIDs (use on a world wipe)
# ==============================================================================
set -uo pipefail

# --- per-server config --------------------------------------------------------
SERVER_TAG="myserver"          # Change as needed (names the state/log files)
LOG_DIR="/opt/app/zomboid/config/Logs"          # Change as needed
PLAYER_DB="/opt/app/zomboid/config/db/My Zomboid Server.db"          # Change as needed
RCON_OPTS="-c /root/rcon.yaml"          # Change as needed
STORMS_DIR="$(cd "$(dirname "$0")" && pwd)"
NEW_KIT=("Base.KnifePocket" "Base.Matches")
RESPAWN_KIT=("Base.KitchenKnife" "Base.Tshirt_WhiteTINT" "Base.Trousers_Denim" "Base.Shoes_TrainerTINT" "Base.Socks_Ankle" "Base.BeefJerky")
# New-player drops only: one random MRE for the new player and for everyone else online.
# (Respawn kits get no MRE, just what is in RESPAWN_KIT.)
MRE_CHOICES=("Base.TinnedBeans" "Base.CannedChili" "Base.BeefJerky")   # e.g. the MRE Mod's bdtmre.* meals
# ------------------------------------------------------------------------------

RCON_BIN=/usr/local/bin/rcon
SEEN="/root/.pz-newplayer-seen-$SERVER_TAG"        # one SteamID per line
DONE="/root/.pz-newplayer-done-$SERVER_TAG"        # processed PerkLog lines
LOG="/root/newplayer-$SERVER_TAG.log"
LOCK="/root/.pz-newplayer-$SERVER_TAG.lock"
GIVE_UP_SECS=300   # retry the triggering player for 5 min (not spawned yet / server restarting), then drop it

log() { echo "$(date '+%F %T') $*" >> "$LOG"; if [[ -t 1 ]]; then echo "$*"; fi; return 0; }
pzrcon() { local -a o; read -ra o <<<"$RCON_OPTS"; "$RCON_BIN" "${o[@]}" "$1" 2>&1; }
touch "$SEEN" "$DONE"

exec 9>"$LOCK"; flock -n 9 || exit 0

pick_mre() { echo "${MRE_CHOICES[RANDOM % ${#MRE_CHOICES[@]}]}"; }

broadcast() {
  local -a ANNOUNCE_MESSAGES=()
  eval "$(sed -n '/^ANNOUNCE_MESSAGES=(/,/^)/p' "$STORMS_DIR/supplydrop.sh")" 2>/dev/null
  (( ${#ANNOUNCE_MESSAGES[@]} )) || return 0
  local msg="${ANNOUNCE_MESSAGES[RANDOM % ${#ANNOUNCE_MESSAGES[@]}]}"
  pzrcon "servermsg \"$msg\"" >/dev/null
  log "  broadcast: $msg"
}

# give <player> <kind> item...
# Returns 1 when nothing was delivered: player offline / not spawned yet, or the
# server/RCON is down. Only the server's own "Added in" reply
# counts as delivered.
give() {
  local p="$1" kind="$2"; shift 2
  local id out got=()
  for id in "$@"; do
    if [[ $DRY -eq 1 ]]; then log "  would give $p <- $id"; continue; fi
    out="$(pzrcon "additem \"$p\" \"$id\" 1")"
    if grep -qi 'added' <<<"$out"; then
      got+=("$id")
    elif grep -qi "doesn't exist" <<<"$out"; then
      log "  BAD ID $p <- $id : $out"
    elif (( ${#got[@]} == 0 )); then
      return 1                       # offline / not spawned yet / server down: try again later
    else
      log "  FAILED $p <- $id : $out"  # part of the kit already went out; don't repeat it
    fi
    sleep 0.3
  done
  [[ $DRY -eq 1 ]] && return 0
  (( ${#got[@]} )) || return 1
  log "  $kind kit -> $p: ${got[*]}"
  return 0
}

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  --seed)
    n0=$(wc -l <"$SEEN")
    sqlite3 -readonly "$PLAYER_DB" "select steamid from whitelist where steamid<>'' and steamid is not null;" >>"$SEEN"
    sort -u -o "$SEEN" "$SEEN"; log "seeded from DB: $n0 -> $(wc -l <"$SEEN") SteamIDs"; exit 0 ;;
  --reset)
    cp "$SEEN" "$SEEN.bak-$(date +%Y%m%d-%H%M%S)"; : >"$SEEN"; log "SteamID list reset (backup kept)"; exit 0 ;;
  "") ;;
  *) sed -n '/^# Usage/,/^# ====/p' "$0"; exit 1 ;;
esac

# First run ever: mark all existing Created lines as processed so history isn't replayed.
if [[ ! -s "$DONE" ]]; then
  find "$LOG_DIR" -name '*PerkLog.txt' -exec grep -h '\]\[Created Player' {} + 2>/dev/null >>"$DONE"
  echo "#init $(date +%s)" >>"$DONE"
  log "initialised: $(grep -vc '^#' "$DONE") historical character creations skipped"
  exit 0
fi

now=$(date +%s)
# [26-09-26 14:59:07.530] [7656...][name][x,y,z][Created Player 1][...]  (kept in a variable: inline, bash mangles the \[ escapes)
LINE_RE='^\[([0-9]{2})-([0-9]{2})-([0-9]{2}) ([0-9:]{8})[^]]*\] \[([0-9]+)\]\[([^]]+)\]'

while IFS= read -r line; do
  grep -qxF "$line" "$DONE" && continue
  # [26-09-26 14:59:07.530] [7656...][name][x,y,z][Created Player 1][Hours Survived: 0].
  [[ "$line" =~ $LINE_RE ]] || continue
  ts=$(date -d "20${BASH_REMATCH[3]}-${BASH_REMATCH[2]}-${BASH_REMATCH[1]} ${BASH_REMATCH[4]}" +%s 2>/dev/null || echo "$now")
  sid="${BASH_REMATCH[5]}"; p="${BASH_REMATCH[6]}"
  if grep -qx "$sid" "$SEEN"; then
    # Death / new character: that player only.
    if give "$p" RESPAWN "${RESPAWN_KIT[@]}"; then
      [[ $DRY -eq 1 ]] && continue
      log "RESPAWN drop for $p"; broadcast; echo "$line" >>"$DONE"
    elif (( now - ts > GIVE_UP_SECS )); then
      log "RESPAWN drop for $p skipped: not in the world"; echo "$line" >>"$DONE"
    fi
  else
    # Brand-new player: full new-player kit to them, an MRE to everyone else online.
    if give "$p" "NEW PLAYER" "${NEW_KIT[@]}" "$(pick_mre)"; then
      mapfile -t online < <(pzrcon players | grep -E '^[[:space:]]*-' | sed 's/^[[:space:]]*-[[:space:]]*//; s/[[:space:]]*$//')
      # everyone else online gets an MRE only (no knife/matches, so nobody stocks up)
      for o in "${online[@]}"; do [[ "$o" == "$p" || -z "$o" ]] || give "$o" "NEW PLAYER share (MRE only)" "$(pick_mre)" || true; done
      [[ $DRY -eq 1 ]] && continue
      log "NEW PLAYER drop for $p, shared with ${#online[@]} online"; broadcast
      echo "$sid" >>"$SEEN"; echo "$line" >>"$DONE"
    elif (( now - ts > GIVE_UP_SECS )); then
      log "NEW PLAYER drop for $p skipped: not in the world (SteamID not recorded, so their next character still counts as new)"; echo "$line" >>"$DONE"
    fi
  fi
done < <(find "$LOG_DIR" -name '*PerkLog.txt' -mmin -60 -exec grep -h '\]\[Created Player' {} + 2>/dev/null | sort)

# keep the processed list bounded
if (( $(wc -l <"$DONE") > 5000 )); then tail -n 3000 "$DONE" >"$DONE.tmp" && mv "$DONE.tmp" "$DONE"; fi
