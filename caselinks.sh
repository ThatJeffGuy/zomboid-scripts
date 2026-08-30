#!/usr/bin/env bash
# ==============================================================================
# Script Name: caselinks.sh
# Description: Resolves Linux case-sensitivity issues for Project Zomboid mods 
#              by recursively scanning Workshop directories and creating lowercase 
#              symlinks for critical animation/actiongroup folders.
#
# Options:
#   --dry-run   Scan and report which symlinks would be created or failed, 
#               without modifying the filesystem.
# ==============================================================================

set -uo pipefail

DRY=false
[[ "${1:-}" == "--dry-run" ]] && DRY=true

CONTENT=/project-zomboid/steamapps/workshop/content/108600
[[ -d "$CONTENT" ]] || { echo "not found: $CONTENT" >&2; exit 1; }

NAMES="AnimSets actiongroups ActionGroups AnimNodes"

made=0; existed=0; skipped=0

while IFS= read -r dir; do
  base="$(basename "$dir")"
  parent="$(dirname "$dir")"
  lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"

  [[ "$lower" == "$base" ]] && continue
  target="$parent/$lower"

  if [[ -e "$target" || -L "$target" ]]; then
    existed=$(( existed + 1 ))
    continue
  fi

  if [[ "$DRY" == true ]]; then
    echo "  would link: $target -> $base"
    made=$(( made + 1 ))
    continue
  fi

  if ln -s "$base" "$target" 2>/dev/null; then
    echo "  linked: $target -> $base"
    made=$(( made + 1 ))
  else
    echo "  !! failed: $target" >&2
    skipped=$(( skipped + 1 ))
  fi
done < <(
  for n in $NAMES; do
    find "$CONTENT" -maxdepth 6 -type d -name "$n" 2>/dev/null
  done | sort -u
)

echo
if [[ "$DRY" == true ]]; then
  echo "DRY RUN: $made link(s) would be created, $existed already present."
else
  echo "created: $made   already present: $existed   failed: $skipped"
fi
