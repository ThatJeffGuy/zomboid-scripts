#!/usr/bin/env bash
#
# pz-caretaking.sh — Wubcord Project Zomboid mod-update watcher
#
# Every hour:
#   1. Asks the PZ server over RCON whether its Workshop mods are stale
#   2. If so, warns connected players, then waits out the warning window
#      (30s for 4 or fewer players, 90s for 5+)
#   3. Saves the world, then issues `quit`
#   4. Docker's `restart: unless-stopped` brings the container back, and
#      UPDATE_ON_START=true makes SteamCMD pull the new mod versions
#   5. Verifies the world actually loaded, then does light housekeeping
#
# If the container is stopped when the script fires, it starts it, waits for
# the world, and exits — no restart, since a cold start updates mods already.
#
# Cron (inside LXC, `crontab -e` as root):
#   10 * * * * /root/pz-caretaking.sh >/dev/null 2>>/root/pz-caretaking.log
#
# log() already tees into the log file, so stdout goes to /dev/null; the 2>>
# catches anything that dies outside log() — python tracebacks, docker errors.
#
# Requires: python3, flock (util-linux), docker CLI. All present in 201
# already except possibly python3 — `apt-get install -y python3-minimal`.
#
# Flags:
#   --dry-run   do everything except save/quit/prune (safe to run anytime)
#   --force     skip the mod check and restart regardless
#   --status    query players + mod state, print, exit
#

set -uo pipefail

# ---------------------------------------------------------------- config ----

CONTAINER=zomboid-server                    # docker container name
RCON_HOST=127.0.0.1                         # network_mode: host, so loopback
RCON_PORT=27015
RCON_PASS_FILE=/root/.pz-rcon       # chmod 600, password only

ZOMBOID_CONFIG=/opt/app/zomboid/config
WORLD_NAME="Wubcord Project Zomboid"

LOGDIR_KEEP_HOURS=24                        # prune PZ Logs/ older than this
DO_IMAGE_PRUNE=true                         # docker image prune -f after restart

# Don't restart during these local hours (24h, inclusive start, exclusive end).
# Leave both empty to disable. Example: QUIET_START=19 QUIET_END=24 defers
# restarts during prime-time play; the next run picks it up.
QUIET_START=""
QUIET_END=""

# Seconds between the warning message and the shutdown, when players are online.
# A fuller server gets longer to find somewhere safe to log out.
WARN_THRESHOLD=4                            # this many players or fewer = short
WARN_SECONDS_SHORT=30
WARN_SECONDS_LONG=90
FINAL_WARN_SECONDS=30                       # second warning at this many seconds
                                            # left; skipped if the window is
                                            # already this short or shorter

BOOT_TIMEOUT=300                            # max seconds to wait after a restart
COLD_BOOT_TIMEOUT=180                       # max seconds when starting from stopped
POLL_INTERVAL=10                            # how often to check during boot
MODCHECK_WAIT=45                            # seconds to wait for async verdict

LOG=/root/pz-caretaking.log
LOG_KEEP_HOURS=48                           # drop log lines older than this
LOCK=/root/pz-caretaking.lock

# Pattern that means "mods are stale" in the server console. Verify this
# against your own logs the first time — see NOTES at the bottom.
STALE_PATTERN='need update'
FRESH_PATTERN='mods updated'

# ------------------------------------------------------------- plumbing ----

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

# Only one instance at a time — a restart cycle can run 20+ minutes.
exec 9>"$LOCK"
flock -n 9 || { log "another run is in progress; exiting"; exit 0; }

[[ -r "$RCON_PASS_FILE" ]] || die "cannot read $RCON_PASS_FILE"
RCON_PASS="$(<"$RCON_PASS_FILE")"
[[ -n "$RCON_PASS" ]] || die "$RCON_PASS_FILE is empty"

command -v python3 >/dev/null || die "python3 not installed in this container"
command -v docker  >/dev/null || die "docker CLI not found"

# ----------------------------------------------------------- rcon client ----

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
        # PZ may emit an empty SERVERDATA_RESPONSE_VALUE before the auth reply
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
            if len(pkt[2]) < 3700:      # short packet == end of response
                break
        print(''.join(out).strip())
    return 0

sys.exit(main())
PYEOF

rcon() {
  python3 "$RCON_PY" "$RCON_HOST" "$RCON_PORT" "$RCON_PASS" "$1" 2>>"$LOG"
}

# -------------------------------------------------------------- helpers ----

# Number of connected players, or -1 if the query failed.
player_count() {
  local out n
  out="$(rcon 'players')" || { echo -1; return; }
  # Expected shape: "Players connected (3): \n-alice\n-bob\n-carol"
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

# Fires checkModsNeedUpdate, waits, then reads the verdict out of the
# container log. Echoes: stale | fresh | unknown
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
    # If the container fell over there is no point burning the whole timeout.
    if ! container_running; then
      log "ERROR: container '$CONTAINER' is no longer running (${waited}s in)"
      return 1
    fi
    # RCON only answers once the server is fully up, so this is the real signal.
    if [[ "$(player_count)" != "-1" ]]; then
      log "server is up and RCON is answering (${waited}s)"
      return 0
    fi
  done
  log "ERROR: server did not confirm healthy within ${timeout}s"
  return 1
}

# Drop log lines older than LOG_KEEP_HOURS. Rewrites the file in place rather
# than mv'ing a temp over it — cron holds this path open in append mode for the
# duration of the run, and replacing the inode would send the rest of this
# run's stderr to a deleted file. Untimestamped lines (cron-captured stderr,
# python tracebacks) inherit the keep/drop decision of the stamped line above.
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

# ------------------------------------------------------------------ main ----

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

# A cold start already ran SteamCMD with UPDATE_ON_START=true, so the mods are
# current by definition. Restarting again — including under --force — would
# just bounce a server that came up 90 seconds ago.
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

# --- warn ---
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

# --- save and quit ---
log "saving world"
rcon 'save' >/dev/null
sleep 15

log "issuing quit"
rcon 'quit' >/dev/null
sleep 10

# --- verify and tidy ---
if wait_for_world; then
  housekeeping
  log "=== run complete: restarted successfully ==="
else
  log "=== run complete: RESTART DID NOT VERIFY — check the container ==="
  exit 1
fi
