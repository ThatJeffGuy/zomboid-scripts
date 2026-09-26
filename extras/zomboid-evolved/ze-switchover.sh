#!/bin/bash
# Switch Zomboid Evolved's server-only scripts from the game's media/lua/server (which is in the
# multiplayer Lua checksum, so ordinary players got kicked) to <config>/Lua/ZomboidEvolved/,
# loaded by the ZomboidEvolvedMap Workshop mod's ZE_ServerScripts.lua. Then re-enable
# DoLuaChecksum. Prepared 2026-09-26.
# Usage: /root/ze-switchover.sh <ZomboidEvolvedMap workshop id> [--dry-run]
set -euo pipefail
WID="${1:-}"; DRY="${2:-}"
[[ "$WID" =~ ^[0-9]+$ ]] || { echo "usage: $0 <workshop id> [--dry-run]"; exit 1; }
BASE=/opt/app/project-evolution
INI="$BASE/config/Server/Project Evolution.ini"
PRESETS=$BASE/config/presets
NEWDIR=$BASE/config/Lua/ZomboidEvolved
GAMEDIR=$BASE/server/media/lua/server
GUARD=/usr/local/sbin/pe-presets-guard.sh
RCON="rcon -c /root/rcon-evolution.yaml"
ORDER=(PE_ServerPresets.lua PE_DinoHeat.lua PE_DinoDamage.lua PE_SpeedProbe.lua)

for f in "${ORDER[@]}"; do [[ -f $PRESETS/$f ]] || { echo "missing $PRESETS/$f"; exit 1; }; done
# loadstring was disabled in 42.20.4 Stable and re-enabled in 42.21: refuse to run on an older build,
# or the dino scripts would stop loading entirely.
VER=$(grep -h -o "version=42\.[0-9]*\.[0-9]*" $(ls -t $BASE/config/Logs/*DebugLog-server.txt | head -1) | head -1 | cut -d= -f2)
MINOR=$(echo "$VER" | cut -d. -f2)
echo "server game version: ${VER:-unknown}"
if [[ -z "$MINOR" || "$MINOR" -lt 21 ]]; then echo "ABORT: needs B42.21+ (loadstring), server is ${VER:-unknown}"; exit 1; fi
echo "plan:"
echo "  scripts  : ${ORDER[*]}  ->  $NEWDIR (+ load.txt); remove $GAMEDIR/PE_*.lua"
echo "  guard    : $GUARD DSTDIR -> $NEWDIR"
echo "  ini      : Mods += ZomboidEvolvedMap, WorkshopItems += $WID, DoLuaChecksum -> true"
echo "  currently: $(grep -E '^DoLuaChecksum=' "$INI"); game-dir PE files: $(ls $GAMEDIR/PE_*.lua 2>/dev/null | wc -l)"
[[ "$DRY" == "--dry-run" ]] && { echo "(dry run, nothing changed)"; exit 0; }

T=$(date +%Y%m%d-%H%M%S)
cp -p "$INI" "$BASE/archive/Project Evolution.ini.bak-$T"
cp -p "$GUARD" "$BASE/archive/pe-presets-guard.sh.bak-$T"

# server scripts -> server-only folder, with the run order
install -d -o 1000 -g 1000 "$NEWDIR"
{ echo "# Run in order by the ZomboidEvolvedMap mod (ZE_ServerScripts.lua). Canonical copies: config/presets/"
  printf '%s\n' "${ORDER[@]}"; } > "$NEWDIR/load.txt"
chown 1000:1000 "$NEWDIR/load.txt"

# preset guard now keeps $NEWDIR in sync and clears the old game-dir copies
python3 - "$GUARD" "$NEWDIR" "$GAMEDIR" <<'PY'
import sys, re
p, new, game = sys.argv[1:4]
s = open(p).read()
s = re.sub(r'(?m)^DSTDIR=.*$', 'DSTDIR=' + new, s)
if 'stale game-dir copies' not in s:
    s = s.replace('for SRC in', '# stale game-dir copies: the game install is in the Lua checksum, so the scripts live in DSTDIR now\nrm -f ' + game + '/PE_*.lua\nfor SRC in', 1)
open(p, 'w').write(s)
PY
"$GUARD"
rm -f "$GAMEDIR"/PE_*.lua
ls -la "$NEWDIR"; echo "game-dir PE files left: $(ls $GAMEDIR/PE_*.lua 2>/dev/null | wc -l)"

# ini: mod goes last (after VRaptor), workshop id, checksum back on
python3 - "$INI" "$WID" <<'PY'
import sys, re
p, wid = sys.argv[1:3]
s = open(p).read()
def add(key, val):
    global s
    m = re.search(r'(?m)^' + key + r'=(.*)$', s)
    items = [x for x in m.group(1).split(';') if x]
    if val not in items: items.append(val)
    s = s[:m.start()] + key + '=' + ';'.join(items) + s[m.end():]
add('Mods', 'ZomboidEvolvedMap'); add('WorkshopItems', wid)
s = re.sub(r'(?m)^DoLuaChecksum=false$', 'DoLuaChecksum=true', s)
open(p, 'w').write(s)
PY
grep -E "^DoLuaChecksum=" "$INI"; grep -E "^(Mods|WorkshopItems)=" "$INI" | grep -o ".\{45\}$"

# restart and verify
if ! $RCON players | grep -q "(0)"; then $RCON "servermsg \"Quick restart in 10 seconds, back in ~2 minutes!\""; sleep 10; fi
$RCON save; sleep 5; $RCON quit; sleep 30
S=$(docker inspect -f "{{.State.StartedAt}}" project-evolution); n=0
until docker logs --since "$S" project-evolution 2>&1 | grep -q "\*\*\* SERVER STARTED"; do sleep 15; n=$((n+1)); [ $n -gt 80 ] && break; done
docker logs --since "$S" project-evolution 2>&1 | grep -E "\*\*\* SERVER STARTED|ZE-Loader|PE-Presets\] dino live|PE-Heat\] safe-zone|PE-Damage\] dino|PE-Speed\] speed|loading ZomboidEvolvedMap" | cut -c1-170
