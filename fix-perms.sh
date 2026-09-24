#!/usr/bin/env bash
# fix-perms.sh — self-healing guard for the storm/caretaking scripts.
#
# Editing these scripts over an SMB share (or any tool that doesn't preserve the
# Unix executable bit) can silently strip +x, and cron runs them as root: once a
# script loses +x, every tick just logs "Permission denied" instead of running,
# which can go unnoticed for days. This re-adds +x whenever it goes missing.
# Run it every 5 minutes from root's crontab so an outage is capped at one tick.
#
# On an unprivileged LXC container, a file that lands owned by nobody:nogroup
# (the kernel's overflow uid -- its real owner is outside the container's mapped
# uid range) can't be chmod'd from inside the container at all, root or not;
# that needs the host. This still fixes everything it can and warns on those.
set -uo pipefail
DIR="/opt/app/zomboid/config/storms"          # Change as needed

for f in "$DIR"/*.sh; do
    [ -x "$f" ] && continue
    if chmod +x "$f" 2>/dev/null; then
        printf '[%s] restored missing +x on %s\n' "$(date '+%F %T')" "$f"
    else
        printf '[%s] WARN: %s lost +x and could not be repaired from inside the container (likely nobody:nogroup overflow-uid -- needs a fix from the host)\n' "$(date '+%F %T')" "$f"
    fi
done
