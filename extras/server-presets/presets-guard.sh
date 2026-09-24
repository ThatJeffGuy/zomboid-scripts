#!/bin/bash
# Keeps the server-only preset script (ServerPresets.lua) in the game install dir.
# The canonical copy lives in the config dir (never touched by game updates); the game
# only runs server Lua from its own install dir, so this restores it if an update
# removes or alters it. Triggered by presets-guard.path and presets-guard.timer.
SRC=/opt/app/zomboid/config/presets/ServerPresets.lua
DST=/opt/app/zomboid/server/media/lua/server/ServerPresets.lua
[[ -r "$SRC" ]] || { echo "canonical copy missing: $SRC" >&2; exit 1; }
[[ -d "$(dirname "$DST")" ]] || { echo "game lua dir missing (game mid-install?): $(dirname "$DST")"; exit 0; }
if [[ -f "$DST" ]] && cmp -s "$SRC" "$DST" && [[ "$(stat -c %u "$DST")" == 1000 ]]; then exit 0; fi
if [[ -f "$DST" ]]; then why="differs from canonical or wrong owner"; else why="missing"; fi
rm -f "$DST"
install -m 0644 -o 1000 -g 1000 "$SRC" "$DST"
echo "restored $DST ($why)"
