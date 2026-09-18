#!/usr/bin/env bash
# ==============================================================================
# Script Name: caretaking.sh
# Description: Automated maintenance and restart manager for a Dockerized
#              Project Zomboid server. Monitors player counts, checks for
#              stale mods via RCON, enforces quiet hours, and handles graceful
#              server reboots with automated in-game warnings. Also recovers
#              from a crashed server process: if RCON can't be reached even
#              though the container is up, it checks whether the game
#              process itself is still alive inside the container and
#              restarts it if not (see game_process_alive()).
#
#              Crash recoveries are rate-limited (see CRASH_LOOP_THRESHOLD) so
#              a genuinely broken server (bad mod, corrupt save) gets a loud
#              alert instead of an endless restart loop, and every crash
#              recovery -- looped or not -- sends a best-effort email alert if
#              GMAIL_USER/GMAIL_APP_PASS/EMAIL_TO are configured (see
#              send_alert()), since a silently self-healing server is still a
#              crash you'd want to know about.
#
# Options:
#   --dry-run   Simulate the process (log actions, calculate warnings) without
#               actually executing Docker or RCON restart commands.
#   --force     Bypass the mod freshness check and force a server restart.
#   --status    Print the current container state and mod update status, then exit.
# ==============================================================================

set -uo pipefail

CONTAINER=zomboid-server
RCON_HOST=127.0.0.1
RCON_PORT=27015
RCON_PASS_FILE=/root/.pz-rcon          # Change as needed
RCON_BIN="/usr/local/bin/rcon"
RCON_OPTS="-c /root/rcon.yaml"

ZOMBOID_CONFIG=/opt/app/zomboid/config          # Change as needed
WORLD_NAME="My Zomboid Server"          # Change as needed

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
LOCK=/root/pz-restart.lock

STALE_PATTERN='need update'
FRESH_PATTERN='mods updated'

# Crash-loop guard: caretaking.sh auto-restarts a crashed server process (see
# game_process_alive() below), but a genuinely broken server would otherwise
# get restarted on every single cron tick forever. If more than
# CRASH_LOOP_THRESHOLD recoveries happen within CRASH_LOOP_WINDOW_SECONDS,
# caretaking.sh stops restarting and escalates instead -- the window then
# ages out on its own (old entries just fall out of CRASH_STATE_FILE), so
# auto-recovery resumes without needing anyone to reset anything by hand.
CRASH_STATE_FILE=/opt/app/zomboid/config/storms/.crash_recoveries
CRASH_LOOP_WINDOW_SECONDS=3600          # 1 hour
CRASH_LOOP_THRESHOLD=3                  # more than this many recoveries in the window trips the guard

# Best-effort email alerts for crash recoveries (see send_alert()). Set these
# in /etc/pz-caretaking.env (root-only, not this script, and not something to
# commit to a repo) rather than here. If `swaks` isn't installed, or these are
# left blank, alerts just get logged instead of emailed; nothing else about
# the run is affected.
GMAIL_USER=""
GMAIL_APP_PASS=""
EMAIL_TO=""
[ -r /etc/pz-caretaking.env ] && . /etc/pz-caretaking.env

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

# Best-effort email alert -- never fails the run. If GMAIL_USER/
# GMAIL_APP_PASS/EMAIL_TO aren't set (see /etc/pz-caretaking.env above) or
# `swaks` isn't installed, this just logs the alert instead of emailing it.
send_alert() {
  local subject="$1" body="$2"
  if [[ -z "$GMAIL_USER" || -z "$GMAIL_APP_PASS" || -z "$EMAIL_TO" ]]; then
    log "ALERT (not emailed -- set GMAIL_USER/GMAIL_APP_PASS/EMAIL_TO in /etc/pz-caretaking.env to enable): $subject"
    return 0
  fi
  if ! command -v swaks >/dev/null; then
    log "ALERT (not emailed -- swaks not installed): $subject"
    return 0
  fi
  swaks --to "$EMAIL_TO" --from "$GMAIL_USER" --server smtp.gmail.com --port 587 \
    --auth plain --auth-user "$GMAIL_USER" --auth-password "$GMAIL_APP_PASS" --tls \
    --header "Subject: $subject" --body "$body" >>"$LOG" 2>&1
}

# Appends "now" to CRASH_STATE_FILE, drops entries older than
# CRASH_LOOP_WINDOW_SECONDS, and echoes how many recoveries (including this
# one) fall within the window -- the crash-loop guard's whole state lives in
# this one file, so it self-clears once crashes stop happening for a while.
record_crash_recovery() {
  local now cutoff kept=()
  now="$(date +%s)"
  cutoff=$(( now - CRASH_LOOP_WINDOW_SECONDS ))
  if [[ -f "$CRASH_STATE_FILE" ]]; then
    while read -r ts; do
      [[ "$ts" =~ ^[0-9]+$ ]] && (( ts >= cutoff )) && kept+=("$ts")
    done < "$CRASH_STATE_FILE"
  fi
  kept+=("$now")
  mkdir -p "$(dirname "$CRASH_STATE_FILE")" 2>/dev/null
  printf '%s\n' "${kept[@]}" > "$CRASH_STATE_FILE"
  echo "${#kept[@]}"
}

container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"
}

container_exists() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"
}

# Whether the actual game server process is still alive *inside* the
# container. The container can stay "running" per docker ps even after the
# Java process behind it dies or wedges -- that's the case RCON alone can't
# tell apart from "wrong password" or "port misconfigured", since either way
# player_count() just comes back -1. Checking the process list directly
# (rather than, say, pinging the RCON port again) is what actually answers
# "did it crash", since a dead process won't be listed here regardless of
# why RCON can't reach it.
game_process_alive() {
  docker top "$CONTAINER" 2>/dev/null | grep -Eiq 'ProjectZomboid64|java'
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
if [[ "$PLAYERS" == "-1" ]]; then
  if game_process_alive; then
    die "RCON is not answering but the server process is still running — check the RCON password/port, this isn't a crash"
  fi

  log "RCON is not answering and the server process is gone even though the container is up — this looks like a crash"

  if [[ "$STATUS_ONLY" == true ]]; then
    log "container '$CONTAINER' has no live server process (not restarting for --status)"
    exit 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would 'docker restart $CONTAINER' to recover from the crashed server process"
    exit 0
  fi

  RECENT_CRASHES="$(record_crash_recovery)"
  if (( RECENT_CRASHES > CRASH_LOOP_THRESHOLD )); then
    log "FATAL: ${RECENT_CRASHES} crash-recoveries in the last $(( CRASH_LOOP_WINDOW_SECONDS / 60 ))m (threshold ${CRASH_LOOP_THRESHOLD}) — refusing to keep auto-restarting"
    send_alert "$CONTAINER is crash-looping" \
      "$(printf '%s has crashed %s times in the last %sm. caretaking.sh has stopped auto-restarting it -- investigate by hand (docker logs %s), then clear %s once fixed if you want auto-recovery to resume before the window ages out on its own.' \
        "$CONTAINER" "$RECENT_CRASHES" "$(( CRASH_LOOP_WINDOW_SECONDS / 60 ))" "$CONTAINER" "$CRASH_STATE_FILE")"
    exit 1
  fi

  # Nobody to warn -- if the process is dead, no one is connected regardless
  # of quiet hours, so recovery isn't deferred the way a mod-update restart
  # is below.
  log "restarting '$CONTAINER' to recover from the crash (${RECENT_CRASHES}/${CRASH_LOOP_THRESHOLD} recent recoveries)"
  docker restart -t 30 "$CONTAINER" >/dev/null 2>>"$LOG" || die "docker restart '$CONTAINER' failed"

  wait_for_world "$COLD_BOOT_TIMEOUT" \
    || die "restarted the container after a crash but the world never came up within ${COLD_BOOT_TIMEOUT}s"

  send_alert "$CONTAINER recovered from a crash" \
    "$(printf '%s crashed and was auto-restarted by caretaking.sh (%s/%s recent recoveries in the last %sm window).' \
      "$CONTAINER" "$RECENT_CRASHES" "$CRASH_LOOP_THRESHOLD" "$(( CRASH_LOOP_WINDOW_SECONDS / 60 ))")"

  housekeeping
  log "=== run complete: recovered from a crashed server process ==="
  exit 0
fi
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
