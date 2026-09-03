#!/usr/bin/env bash
#
# pz-event-lib.sh — shared engine for the Wubcord event scripts.
# Not run directly. Each event-*.sh sources this and calls run_event "$@".
#
# Every event is built by patching a pristine baseline, so events can never
# stack and ending one is just "apply the baseline with no overrides".

set -euo pipefail

# ---------------------------------------------------------------- config ---
CONFIG_DIR="/opt/wubcord/Zomboid/Server"
SERVER_CONFIG_NAME="Project Wubcord"     # NOTE: contains a space. Keep it quoted.
COMPOSE_DIR="/opt/wubcord"
CONTAINER="pzserver"

RCON_HOST="127.0.0.1"
RCON_PORT="27015"
RCON_PASS_FILE="/etc/wubcord/rcon.pass"  # chmod 600

WARN_MINUTES=5                           # 0 to restart immediately

# Permanent top of the MOTD. The event block is appended below it.
BASE_MOTD="Welcome to the Crater of Trade. A world built by ScottishHaze. Questions or problems, come to the PMW Discord. Have fun!"

INI_FILE="${CONFIG_DIR}/${SERVER_CONFIG_NAME}.ini"
SANDBOX_FILE="${CONFIG_DIR}/${SERVER_CONFIG_NAME}_SandboxVars.lua"
BASELINE_FILE="/opt/wubcord/scripts/baseline_SandboxVars.lua"
LOCK_FILE="/var/lock/wubcord-server.lock"   # share with pz-caretaking.sh
END_UNIT="wubcord-event-end"                # systemd unit name for the auto-revert

# ------------------------------------------------------------------ guts ---
log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die()  { log "ERROR: $*" >&2; exit 1; }
rcon() { mcrcon -H "$RCON_HOST" -P "$RCON_PORT" -p "$(cat "$RCON_PASS_FILE")" -w 1 "$@"; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ]; }

# When does this event end? EVENT_END_TIME wins if set, otherwise EVENT_HOURS
# from now. Returns a unix timestamp. This one value drives both the MOTD line
# and the scheduled revert, so they can never disagree.
#
# EVENT_END_TIME is an hour of the day, 1-24, on a 24h clock:
#   4  -> 04:00      16 -> 16:00      24 -> midnight
# If that hour has already gone by today, it rolls to tomorrow.
# "HH:MM" is still accepted if you ever need a non-round time.
end_epoch() {
  local t spec="${EVENT_END_TIME:-}"
  if [ -n "$spec" ]; then
    if [[ "$spec" =~ ^[0-9]+$ ]]; then
      if [ "$spec" -lt 1 ] || [ "$spec" -gt 24 ]; then
        die "EVENT_END_TIME must be an hour from 1 to 24 (got: $spec)"
      fi
      [ "$spec" -eq 24 ] && spec=0
      spec="$(printf '%02d:00' "$spec")"
    elif ! [[ "$spec" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then
      die "EVENT_END_TIME must be an hour from 1 to 24, or HH:MM (got: $spec)"
    fi
    t="$(date -d "today ${spec}" +%s)"
    [ "$t" -le "$(date +%s)" ] && t="$(date -d "tomorrow ${spec}" +%s)"
    echo "$t"
  else
    if ! [[ "${EVENT_HOURS:-}" =~ ^[0-9]+$ ]] || [ "${EVENT_HOURS}" -lt 1 ]; then
      die "this event sets neither EVENT_END_TIME nor a numeric EVENT_HOURS - it has no end time"
    fi
    date -d "+${EVENT_HOURS} hours" +%s
  fi
}

cancel_timer() {
  systemctl stop "${END_UNIT}.timer" >/dev/null 2>&1 || true
  systemctl reset-failed "${END_UNIT}.service" >/dev/null 2>&1 || true
  if command -v atq >/dev/null 2>&1 && [ -f /var/run/wubcord-event.atjob ]; then
    atrm "$(cat /var/run/wubcord-event.atjob)" >/dev/null 2>&1 || true
    rm -f /var/run/wubcord-event.atjob
  fi
}

# Schedule "$self --end" to fire at an absolute timestamp. systemd first (no
# extra package), then at(1), then give up loudly with the cron line to paste.
schedule_end() {
  local when="$1" self="$2" secs
  secs=$(( when - $(date +%s) ))
  [ "$secs" -lt 60 ] && secs=60

  cancel_timer

  if command -v systemd-run >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    if systemd-run --unit="$END_UNIT" --on-active="${secs}s" \
         --timer-property=AccuracySec=30s --quiet \
         "$self" --end >/dev/null 2>&1; then
      log "Auto-end scheduled for $(date -d "@${when}" '+%F %H:%M') (systemd: ${END_UNIT}.timer)"
      return 0
    fi
  fi

  if command -v at >/dev/null 2>&1; then
    local jid
    jid="$(echo "$self --end" | at -t "$(date -d "@${when}" +%Y%m%d%H%M)" 2>&1 | grep -oP 'job \K[0-9]+' || true)"
    if [ -n "$jid" ]; then
      echo "$jid" > /var/run/wubcord-event.atjob
      log "Auto-end scheduled for $(date -d "@${when}" '+%F %H:%M') (at job ${jid})"
      return 0
    fi
  fi

  log "WARNING: could not schedule the auto-end. THE EVENT WILL NOT END BY ITSELF."
  log "         Run this when you want it over:  $self --end"
  log "         Or add a one-off cron line:      $(date -d "@${when}" '+%M %H %d %m') *  $self --end"
  return 1
}

usage() {
  cat <<USAGE
usage: $(basename "$0") [--end] [--dry]

  (no flags)   start the event, and schedule its own end automatically
  --end        end it now: restore baseline settings and the plain MOTD
  --dry        build everything, show the diff, change nothing
  --no-timer   start it, but do NOT schedule the auto-end (you'll end it yourself)
USAGE
  exit 0
}

run_event() {
  local mode="start" dry=0 timer=1
  local self; self="$(readlink -f "$0")"
  while [ $# -gt 0 ]; do
    case "$1" in
      --end)  mode="end" ;;
      --dry)  dry=1 ;;
      --no-timer) timer=0 ;;
      -h|--help) usage ;;
      *) die "unknown flag: $1" ;;
    esac
    shift
  done

  local overrides motd ini_over
  if [ "$mode" = "end" ]; then
    overrides=""
    ini_over="${INI_END:-}"
    motd="$BASE_MOTD"
  else
    overrides="$OVERRIDES"
    ini_over="${INI_START:-}"
    local until_str
    ENDS_AT="$(end_epoch)"
    until_str="$(date -d "@${ENDS_AT}" '+%A %-I:%M %p')"
    motd="${BASE_MOTD} <LINE> <LINE> <RGB:1,0.6,0>NOW ON: ${EVENT_NAME} <LINE> ${EVENT_BLURB} <LINE> <RGB:0.7,0.7,0.7>Back to normal ${until_str}."
  fi

  for f in "$INI_FILE" "$SANDBOX_FILE" "$BASELINE_FILE"; do
    [ -f "$f" ] || die "missing $f"
  done

  local staged_lua staged_ini
  staged_lua="$(mktemp)"; staged_ini="$(mktemp)"
  trap 'rm -f "$staged_lua" "$staged_ini"' RETURN

  # One pass: patch the sandbox baseline, and rewrite ServerWelcomeMessage.
  # Tracks table nesting, so top-level Farming and MultiplierConfig.Farming stay
  # distinct, and skips comment lines whose scale legends ("-- 1 = Insane") look
  # exactly like assignments. Aborts on a key it can't find, so a typo fails
  # loudly instead of silently doing nothing.
  OVERRIDES="$overrides" MOTD="$motd" INI_OVERRIDES="$ini_over" python3 - \
    "$BASELINE_FILE" "$staged_lua" "$INI_FILE" "$staged_ini" <<'PY'
import os, re, sys
base, out_lua, ini, out_ini = sys.argv[1:5]

want = {}
for line in os.environ["OVERRIDES"].splitlines():
    line = line.split('#')[0].strip()          # trailing "# was 3" notes
    if not line:
        continue
    k, v = line.split('=', 1)
    want[k.strip()] = v.strip().rstrip(',').strip()

OPEN   = re.compile(r'^\s*([A-Za-z_]\w*)\s*=\s*\{\s*$')
CLOSE  = re.compile(r'^\s*\},?\s*$')
ASSIGN = re.compile(r'^(\s*)([A-Za-z_]\w*)\s*=\s*(.*?),?\s*$')

stack, hit, lines = [], set(), []
for raw in open(base, encoding='utf-8'):
    line = raw.rstrip('\n')
    if line.strip().startswith('--'):
        lines.append(line); continue
    m = OPEN.match(line)
    if m:
        stack.append(m.group(1)); lines.append(line); continue
    if CLOSE.match(line):
        if stack: stack.pop()
        lines.append(line); continue
    m = ASSIGN.match(line)
    if m and stack:
        path = '.'.join(stack[1:] + [m.group(2)])   # drop the SandboxVars root
        if path in want:
            lines.append(f"{m.group(1)}{m.group(2)} = {want[path]},")
            hit.add(path); continue
    lines.append(line)

missing = sorted(set(want) - hit)
if missing:
    sys.exit("keys not found in baseline: " + ", ".join(missing))

open(out_lua, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')

# --- ini: the MOTD, plus any INI_OVERRIDES this event declares ---
ini_want = {}
for line in os.environ.get("INI_OVERRIDES", "").splitlines():
    line = line.split('#')[0].strip()
    if not line:
        continue
    k, v = line.split('=', 1)
    ini_want[k.strip()] = v.strip()

motd, found, ini_hit = os.environ["MOTD"], False, set()
with open(ini, encoding='utf-8') as fh, open(out_ini, 'w', encoding='utf-8') as w:
    for line in fh:
        if line.startswith('ServerWelcomeMessage='):
            w.write(f"ServerWelcomeMessage={motd}\n"); found = True
            continue
        key = line.split('=', 1)[0] if '=' in line and not line.startswith('#') else None
        if key in ini_want:
            w.write(f"{key}={ini_want[key]}\n"); ini_hit.add(key)
        else:
            w.write(line)
    if not found:
        w.write(f"ServerWelcomeMessage={motd}\n")

ini_missing = sorted(set(ini_want) - ini_hit)
if ini_missing:
    sys.exit("ini keys not found: " + ", ".join(ini_missing))

extra = f", {len(ini_hit)} ini key(s)" if ini_hit else ""
print(f"{len(hit)} sandbox override(s) applied, MOTD rewritten{extra}")
PY

  if [ "$dry" = 1 ]; then
    log "DRY RUN (${mode}) — sandbox diff:"
    diff -u "$SANDBOX_FILE" "$staged_lua" || true
    log "DRY RUN — MOTD would be:"
    grep '^ServerWelcomeMessage=' "$staged_ini"
    return 0
  fi

  # One restart at a time across all Wubcord automation.
  exec 9>"$LOCK_FILE"
  flock -w 1800 9 || die "another job holds $LOCK_FILE"

  if running; then
    if [ "$WARN_MINUTES" -gt 0 ]; then
      if [ "$mode" = "end" ]; then
        rcon "servermsg \"${EVENT_NAME} ends in ${WARN_MINUTES} minutes. Server will restart.\"" >/dev/null || true
      else
        rcon "servermsg \"Server restarting in ${WARN_MINUTES} minutes: ${EVENT_NAME} is starting.\"" >/dev/null || true
      fi
      log "Warned players, waiting ${WARN_MINUTES}m"
      sleep $(( WARN_MINUTES * 60 ))
    fi
    log "Saving and shutting down"
    rcon "save" >/dev/null || log "WARN: save failed"
    sleep 20
    rcon "quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do running || break; sleep 5; done
    running && { log "Forcing stop"; docker stop -t 120 "$CONTAINER" >/dev/null; }
  fi

  cp -a "$SANDBOX_FILE" "${SANDBOX_FILE}.prev"
  cp -a "$INI_FILE"     "${INI_FILE}.prev"
  install -m 644 "$staged_lua" "$SANDBOX_FILE"
  install -m 644 "$staged_ini" "$INI_FILE"

  if [ "$mode" = "end" ]; then
    cancel_timer
    log "Ended: ${EVENT_NAME} — baseline restored"
  else
    log "Started: ${EVENT_NAME}"
    if [ "$timer" = 1 ]; then
      schedule_end "$ENDS_AT" "$self" || true
    else
      log "--no-timer: you must run '$self --end' yourself"
    fi
  fi

  ( cd "$COMPOSE_DIR" && docker compose up -d )
  log "Server starting."
}
