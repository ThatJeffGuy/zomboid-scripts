#!/bin/bash
# One-shot reminder (set up 2026-09-26): email when Project Zomboid B42.21+ reaches Stable, because
# 42.21 re-enables loadstring and Zomboid Evolved can then turn its Lua checksum back on.
# Signals: the "Stable Build: x.y.z" banner on projectzomboid.com, or the version Evolved's
# server itself logs (it self-updates on restart). Sends once, then stays quiet.
# Cron: daily. Test without sending: /root/pz-4221-reminder.sh --dry-run
set -uo pipefail
DONE=/root/.pz-4221-reminded
FAILS=/root/.pz-4221-fetch-failures
LOG=/var/log/pz-4221-reminder.log
DRY=${1:-}
[ -f "$DONE" ] && [ "$DRY" != "--dry-run" ] && exit 0
log() { echo "$(date '+%F %T') $*" >> "$LOG"; [ -t 1 ] && echo "$*"; return 0; }
mail() { if [ "$DRY" = "--dry-run" ]; then printf 'WOULD EMAIL: %s\n%s\n' "$1" "$2"; else printf 'Subject: %s\n\n%s\n' "$1" "$2" | /usr/sbin/sendmail root; fi; }

site=$(curl -sL --max-time 30 -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Safari/537.36" https://projectzomboid.com/blog/ \
       | tr "<>" "\n\n" | grep -o -E "Stable Build: *[0-9]+\.[0-9]+(\.[0-9]+)?" | head -1 | grep -o -E "[0-9]+\.[0-9]+(\.[0-9]+)?")
srv=$(pct exec 201 -- sh -c 'grep -h -o "version=42\.[0-9]*\.[0-9]*" $(ls -t /opt/app/project-evolution/config/Logs/*DebugLog-server.txt | head -1) 2>/dev/null | head -1' | cut -d= -f2)
log "site stable=${site:-?} evolved server=${srv:-?}"

if [ -z "$site" ]; then
    n=$(( $(cat "$FAILS" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAILS"
    if [ "$n" -eq 7 ]; then
        mail "PZ 42.21 reminder can't read projectzomboid.com" "The daily check in /root/pz-4221-reminder.sh on $(hostname) has failed to read the Stable build from https://projectzomboid.com/blog/ for 7 days. Check the site manually for 42.21 Stable (loadstring re-enabled), or fix the script. Log: $LOG"
        log "sent fetch-failure email"
    fi
else
    echo 0 > "$FAILS"
fi

newer() { [ -n "$1" ] && [ "$(echo "$1" | cut -d. -f1)" -ge 42 ] && [ "$(echo "$1" | cut -d. -f2)" -ge 21 ]; }
if newer "$site" || newer "$srv"; then
    mail "Zomboid Evolved: B42.21 is Stable - turn the Lua checksum back on" "Project Zomboid ${site:-$srv} is now the Stable build (website: ${site:-unknown}, Evolved server: ${srv:-unknown}).

42.21 re-enables loadstring, so Zomboid Evolved can go back to DoLuaChecksum=true (it has been off since 2026-09-26 because the dino scripts live in the game folder, which players don't have).

What to do:
1. Make sure the Evolved server has updated: its log should say version=42.21 or newer (restart it if it still says 42.20.x - it updates itself on restart).
2. Make sure the Zomboid Evolved Map mod is uploaded to the Workshop and you know its Workshop ID.
3. Ask Claude to run it, or run it yourself on CT 201:  /root/ze-switchover.sh <map workshop id>
   It moves the dino scripts to config/Lua/ZomboidEvolved, adds the map mod (which now loads them), turns the checksum back on and restarts. It refuses to run on anything older than 42.21.
4. Check the output for '[ZE-Loader] loaded 4 server script(s)'.

This reminder was sent once by /root/pz-4221-reminder.sh on $(hostname); it won't send again."
    if [ "$DRY" != "--dry-run" ]; then touch "$DONE"; fi
    log "42.21+ detected, reminder sent"
fi
