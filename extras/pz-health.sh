#!/usr/bin/env bash
# Read-only health snapshot for one PZ container. Run on the host running the game container.
# Usage: pz-health.sh [container] [config-dir] [rcon-yaml]
# Loop it for a soak test:  while :; do pz-health.sh; sleep 300; done | tee -a /root/pz-soak.log
set -u
CONTAINER="${1:-zomboid-server}"
CONF="${2:-/opt/app/zomboid/config}"
RCON_YAML="${3:-/root/rcon.yaml}"
CONSOLE="$CONF/server-console.txt"

# Errors both servers log on every boot (vanilla B42 map data), not worth alerting on.
BENIGN='ThumpSound|Mannequin zone missing|duplicate RoomDef.metaID|invalid room metaID|lookupOrDefaultStr'

echo "=== $(date '+%F %T') $CONTAINER"
docker inspect -f 'state={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{end}} started={{.State.StartedAt}} restarts={{.RestartCount}} oom={{.State.OOMKilled}}' "$CONTAINER"
docker stats --no-stream --format 'cpu={{.CPUPerc}} mem={{.MemUsage}} ({{.MemPerc}})' "$CONTAINER"

ports="$(ini() { grep -m1 "^$1=" "$CONF/Server/"*.ini | cut -d= -f2; }; echo "$(ini DefaultPort) $(ini UDPPort) $(ini RCONPort)")"
for p in $ports; do
  ss -lunt | grep -q ":$p\b" && echo "port $p listening" || echo "port $p NOT LISTENING"
done

echo "players: $(/usr/local/bin/rcon -c "$RCON_YAML" players 2>&1 | head -1)"

boot_line="$(grep -n 'SERVER STARTED' "$CONSOLE" | tail -1 | cut -d: -f1)"
if [[ -n "$boot_line" ]]; then
  since="$(tail -n +"$boot_line" "$CONSOLE")"
  echo "since boot: errors=$(grep -E '^ERROR' <<<"$since" | grep -cvE "$BENIGN") exceptions=$(grep -c 'Exception' <<<"$since") saves=$(grep -c 'Saving finish' <<<"$since")"
  grep -E '^ERROR|Exception' <<<"$since" | grep -vE "$BENIGN" | sed -E 's/st:[0-9,]+//' | sort | uniq -c | sort -rn | head -5
  grep -E 'SaveAll took' <<<"$since" | tail -1
else
  echo "no SERVER STARTED line in console yet"
fi
