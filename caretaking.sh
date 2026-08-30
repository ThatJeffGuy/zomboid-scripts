# Script coded by Scottish Haze aka ThatJeffGuy on Github.
# Code ran through Cwen3 for verification of structure.
# All code posted has successfully run on a prod game server without issues!
# Please post bugs on the github.

#!/usr/bin/env bash

set -uo pipefail

CONTAINER=zomboid-server
RCON_HOST=127.0.0.1
RCON_PORT=27015
RCON_PASS_FILE=/root/.pz-rcon          # Change as needed

ZOMBOID_CONFIG=/opt/app/zomboid/config          # Change as needed
WORLD_NAME="Your Server Name"          # Change as needed

LOGDIR_KEEP_HOURS=24
DO_IMAGE_PRUNE=true

QUIET_START=""          # 1-24 hours
QUIET_END=""          # 1-24 hours

WARN_THRESHOLD=4
WARN_SECONDS_SHORT=30
WARN_SECONDS_LONG=90
FINAL_WARN_SECONDS=30

BOOT_TIMEOUT=300
COLD_BOOT_TIMEOUT=180
POLL_INTERVAL=10
MODCHECK_WAIT=45

LOG=/root/pz-caretaking.log            # Change as needed
LOG_KEEP_HOURS=48
LOCK=/root/pz-caretaking.lock          # Change as needed

STALE_PATTERN='need update'
FRESH_PATTERN='mods updated'

DRY_RUN=false
FORCE=false
STATUS_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --force)   FORCE=true ;;
    --status)  STATUS_ONLY=true ;;
    *) echo "unknown flag: $arg" >&2; exit 64 ;;
  esac
done

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
die() { log "FATAL: $*"; exit 1; }

exec 9>"$LOCK"
flock -n 9 || { log "another run is in progress; exiting"; exit 0; }

[[ -r "$RCON_PASS_FILE" ]] || die "cannot read $RCON_PASS_FILE"
RCON_PASS="$(<"$RCON_PASS_FILE")"
[[ -n "$RCON_PASS" ]] || die "$RCON_PASS_FILE is empty"

command -v python3 >/dev/null || die "python3 not installed in this container"
command -v docker  >/dev/null || die "docker CLI not found"

RCON_PY="$(mktemp /tmp/pzrcon.XXXXXX.py)"
trap 'rm -f "$RCON_PY"' EXIT

cat >"$RCON_PY" <<'PYEOF'
import socket, struct, sys

SERVERDATA_AUTH, SERVERDATA_EXECCOMMAND = 3, 2

def encode(rid, typ, body):
    payload = struct.pack('<ii', rid, typ) + body.encode('utf-8') + b'\x00\x00'
    return struct.pack('<i', len(payload)) + payload

def recvall(sock, n):
    buf = b''
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf

def decode(sock):
    head = recvall(sock, 4)
    if not head:
        return None
    (length,) = struct.unpack('<i', head)
    data = recvall(sock, length)
    if data is None:
        return None
    rid, typ = struct.unpack('<ii', data[:8])
    return rid, typ, data[8:-2].decode('utf-8', 'replace')

def main():
    host, port, password, command = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    try:
        sock = socket.create_connection((host, port), timeout=10)
    except OSError as e:
        print("connect failed: %s" % e, file=sys.stderr)
        return 3
    sock.settimeout(10)
    with sock:
        sock.sendall(encode(1, SERVERDATA_AUTH, password))
        reply = decode(sock)
        if reply and reply[1] == 0:
            reply = decode(sock)
        if not reply or reply[0] == -1:
            print("auth failed", file=sys.stderr)
            return 2
        sock.sendall(encode(2, SERVERDATA_EXECCOMMAND, command))
        out = []
        while True:
            try:
                pkt = decode(sock)
            except socket.timeout:
                break
            if pkt is None:
                break
            out.append(pkt[2])
            if len(pkt[2]) < 3700:
                break
        print(''.join(out).strip())
    return 0

sys.exit(main())
PYEOF

rcon() {
  python3 "$RCON_PY" "$RCON_HOST" "$RCON_PORT" "$RCON_PASS" "$1" 2>>"$LOG"
}

player_count() {
  local out n
  out="$(rcon 'players')" || { echo -1; return; }
  n="$(sed -n 's/.*connected[^(]*(\([0-9]\+\)).*/\1/p' <<<"$out" | head -1)"
  if [[ -z "$n" ]]; then
    n="$(grep -c '^[[:space:]]*-' <<<"$out")"
  fi
  [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo -1
}

container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"
}

container_exists() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"
}

warn_seconds() {
  local n="$1"
  if (( n > WARN_THRESHOLD )); then
    echo "$WARN_SECONDS_LONG"
  else
    echo "$WARN_SECONDS_SHORT"
  fi
}

in_quiet_hours() {
  [[ -n "$QUIET_START" && -n "$QUIET_END" ]] || return 1
  local h; h=10#"$(date +%H)"
  (( h >= QUIET_START && h < QUIET_END ))
}

mods_are_stale() {
  local since_marker verdict
  since_marker="$(( MODCHECK_WAIT + 15 ))s"

  rcon 'checkModsNeedUpdate' >/dev/null
  sleep "$MODCHECK_WAIT"

  verdict="$(docker logs --since "$since_marker" "$CONTAINER" 2>&1 \
             | grep -i 'CheckModsNeedUpdate' | tail -5)"

  if [[ -z "$verdict" ]]; then
    echo unknown
  elif grep -qi "$STALE_PATTERN" <<<"$verdict"; then
    echo stale
  elif grep -qi "$FRESH_PATTERN" <<<"$verdict"; then
    echo fresh
  else
    echo unknown
  fi
}

wait_for_world() {
  local timeout="${1:-$BOOT_TIMEOUT}" waited=0
  log "waiting for the world to come up (timeout ${timeout}s)..."
  while (( waited < timeout )); do
    sleep "$POLL_INTERVAL"; waited=$(( waited + POLL_INTERVAL ))
    if ! container_running; then
      log "ERROR: container '$CONTAINER' is no longer running (${waited}s in)"
      return 1
    fi
    if [[ "$(player_count)" != "-1" ]]; then
      log "server is up and RCON is answering (${waited}s)"
      return 0
    fi
  done
  log "ERROR: server did not confirm healthy within ${timeout}s"
  return 1
}

trim_log() {
  [[ -f "$LOG" && -w "$LOG" ]] || return 0
  local cutoff
  cutoff="$(date -d "$LOG_KEEP_HOURS hours ago" '+%Y-%m-%d %H:%M:%S')" || return 0
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

housekeeping() {
  log "running maintenance"

  find "$ZOMBOID_CONFIG/Logs" -type f -mmin +$(( LOGDIR_KEEP_HOURS * 60 )) -delete 2>/dev/null \
    && log "pruned PZ logs older than ${LOGDIR_KEEP_HOURS}h"

  if [[ "$DO_IMAGE_PRUNE" == true ]]; then
    local freed
    freed="$(docker image prune -f 2>/dev/null | tail -1)"
    log "docker image prune: ${freed:-nothing reclaimed}"
  fi
}

trim_log
log "=== run start (dry_run=$DRY_RUN force=$FORCE) ==="

COLD_START=false

if ! container_running; then
  container_exists || die "container '$CONTAINER' does not exist on this host"

  if [[ "$STATUS_ONLY" == true ]]; then
    log "container '$CONTAINER' is stopped (not starting it for --status)"
    exit 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: container is stopped; would 'docker start $CONTAINER' and wait for the world"
    exit 0
  fi

  log "container '$CONTAINER' is stopped — starting it"
  docker start "$CONTAINER" >/dev/null 2>>"$LOG" || die "docker start '$CONTAINER' failed"
  COLD_START=true

  wait_for_world "$COLD_BOOT_TIMEOUT" \
    || die "started the container but the world never came up within ${COLD_BOOT_TIMEOUT}s"
fi

PLAYERS="$(player_count)"
[[ "$PLAYERS" == "-1" ]] && die "RCON is not answering — check the password and port"
log "players online: $PLAYERS"

if [[ "$STATUS_ONLY" == true ]]; then
  log "mod state: $(mods_are_stale)"
  exit 0
fi

if [[ "$COLD_START" == true ]]; then
  log "cold start complete; mods were updated on boot, no restart needed"
  housekeeping
  log "=== run complete: container was down, started it ==="
  exit 0
fi

if [[ "$FORCE" == true ]]; then
  log "--force given; skipping mod check"
else
  STATE="$(mods_are_stale)"
  log "mod state: $STATE"
  case "$STATE" in
    fresh)   log "nothing to do"; exit 0 ;;
    unknown) log "could not read a verdict from the logs; not restarting"; exit 0 ;;
    stale)   log "mods are stale — proceeding to restart" ;;
  esac
fi

if in_quiet_hours; then
  log "inside quiet hours (${QUIET_START}:00–${QUIET_END}:00) — deferring to next run"
  exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
  log "DRY RUN: would warn ${PLAYERS} player(s) with a $(warn_seconds "$PLAYERS")s window, then save and quit"
  exit 0
fi

if (( PLAYERS > 0 )); then
  WARN="$(warn_seconds "$PLAYERS")"
  msg="Server restarting in ${WARN} seconds for mod updates — get somewhere safe."
  log "warn: ${PLAYERS} player(s) online, ${WARN}s window"
  log "warn: $msg"
  rcon "servermsg \"$msg\"" >/dev/null

  if (( WARN > FINAL_WARN_SECONDS )); then
    sleep $(( WARN - FINAL_WARN_SECONDS ))
    final="Server restarting in ${FINAL_WARN_SECONDS} seconds — log out somewhere safe now."
    log "warn: $final"
    rcon "servermsg \"$final\"" >/dev/null
    sleep "$FINAL_WARN_SECONDS"
  else
    sleep "$WARN"
  fi
else
  log "nobody online; restarting immediately"
fi

log "saving world"
rcon 'save' >/dev/null
sleep 15

log "issuing quit"
rcon 'quit' >/dev/null
sleep 10

if wait_for_world; then
  housekeeping
  log "=== run complete: restarted successfully ==="
else
  log "=== run complete: RESTART DID NOT VERIFY — check the container ==="
  exit 1
fi
