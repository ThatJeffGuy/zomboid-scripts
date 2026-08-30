# ==============================================================================
# Script Name: refetch.sh
# Description: Forces a clean redownload of a specific Project Zomboid Workshop 
#              mod by purging its downloaded directory and dynamically removing 
#              its entry from the SteamCMD appworkshop manifest (.acf).
#
# Usage: 
#   ./refetch.sh <workshop-id> [--dry-run]
#
# Options:
#   <workshop-id>  (Required) The numeric Steam Workshop ID of the mod to purge.
#   --dry-run      Show which lines in the manifest would be deleted, without 
#                  modifying files or deleting the content directory.
# ==============================================================================
#!/usr/bin/env bash

set -uo pipefail

WSID="${1:?usage: $0 <workshop-id> [--dry-run]}"
DRY=false
[[ "${2:-}" == "--dry-run" ]] && DRY=true

[[ "$WSID" =~ ^[0-9]+$ ]] || { echo "Not a numeric Workshop ID: $WSID" >&2; exit 1; }

STEAMAPPS=/project-zomboid/steamapps/workshop
CONTENT="$STEAMAPPS/content/108600/$WSID"
ACF="$STEAMAPPS/appworkshop_108600.acf"

echo "workshop id : $WSID"
echo "content dir : $CONTENT"
echo "manifest    : $ACF"
echo

if [[ -d "$CONTENT" ]]; then
  echo "content dir present ($(du -sh "$CONTENT" 2>/dev/null | cut -f1))"
else
  echo "content dir NOT present (already removed?)"
fi

if [[ ! -f "$ACF" ]]; then
  echo "!! manifest not found at $ACF" >&2
  echo "   Check the path before continuing — without editing it, Steam will" >&2
  echo "   think the item is still installed and skip the download." >&2
  exit 1
fi

grep -c "\"$WSID\"" "$ACF" >/dev/null 2>&1
hits="$(grep -c "\"$WSID\"" "$ACF" || true)"
echo "manifest entries for this id: $hits"

if [[ "$DRY" == true ]]; then
  echo
  echo "DRY RUN — nothing changed. Manifest blocks that would be removed:"
  python3 - "$ACF" "$WSID" --show <<'PY'
import sys
path, wsid = sys.argv[1], sys.argv[2]
lines = open(path, encoding='utf-8', errors='replace').read().split('\n')
i = 0
while i < len(lines):
    if lines[i].strip() == '"%s"' % wsid:
        depth = 0; j = i + 1
        while j < len(lines) and '{' not in lines[j]:
            j += 1
        start = i
        while j < len(lines):
            depth += lines[j].count('{') - lines[j].count('}')
            if depth == 0:
                break
            j += 1
        print('  lines %d-%d:' % (start + 1, j + 1))
        for k in range(start, min(j + 1, len(lines))):
            print('   ', lines[k])
        i = j + 1
        continue
    i += 1
PY
  exit 0
fi

BACKUP="${ACF}.bak.$(date +%Y%m%d-%H%M%S)"
cp -p "$ACF" "$BACKUP"
echo "manifest backup: $BACKUP"

python3 - "$ACF" "$WSID" <<'PY'
import sys
path, wsid = sys.argv[1], sys.argv[2]
lines = open(path, encoding='utf-8', errors='replace').read().split('\n')
out, i, removed = [], 0, 0
while i < len(lines):
    if lines[i].strip() == '"%s"' % wsid:
        j = i + 1
        while j < len(lines) and '{' not in lines[j]:
            j += 1
        depth = 0
        while j < len(lines):
            depth += lines[j].count('{') - lines[j].count('}')
            if depth == 0:
                break
            j += 1
        removed += 1
        i = j + 1
        continue
    out.append(lines[i])
    i += 1
open(path, 'w', encoding='utf-8').write('\n'.join(out))
print("removed %d manifest block(s)" % removed)
PY

if [[ -d "$CONTENT" ]]; then
  rm -rf "$CONTENT" && echo "deleted $CONTENT"
fi

echo
echo "Done. Start the server; SteamCMD will fetch only $WSID."
