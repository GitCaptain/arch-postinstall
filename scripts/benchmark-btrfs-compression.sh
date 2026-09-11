#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE="${1:-}"
[[ -n "$SOURCE" ]] && shift || true
LEVELS=("$@")
((${#LEVELS[@]})) || LEVELS=(1 3 5 8)
WORK_ROOT="/var/tmp/btrfs-compression-bench"

usage() {
  cat <<'HELP'
Usage:
  ./scripts/benchmark-btrfs-compression.sh SOURCE [LEVEL ...]

Examples:
  ./scripts/benchmark-btrfs-compression.sh /usr/bin
  ./scripts/benchmark-btrfs-compression.sh ~/real-data 1 3 5 8

The source is never modified. A temporary copy is recompressed at each Zstd
level and measured with compsize. Requires btrfs-progs and compsize.
HELP
}

[[ -n "$SOURCE" ]] || { usage; exit 2; }
[[ -e "$SOURCE" ]] || { echo "Source does not exist: $SOURCE" >&2; exit 1; }
for cmd in btrfs compsize findmnt; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done

sudo mkdir -p "$WORK_ROOT"
fs="$(findmnt -no FSTYPE -T "$WORK_ROOT")"
[[ "$fs" == "btrfs" ]] || { echo "$WORK_ROOT is on '$fs', not Btrfs." >&2; exit 1; }

cleanup() { sudo rm -rf "$WORK_ROOT/data" 2>/dev/null || true; }
trap cleanup EXIT

printf 'Source: %s\n' "$SOURCE"
printf 'Levels: %s\n\n' "${LEVELS[*]}"
printf '%-12s %-14s\n' "zstd level" "rewrite_ms"
printf '%-12s %-14s\n' "----------" "----------"

for level in "${LEVELS[@]}"; do
  [[ "$level" =~ ^-?[0-9]+$ ]] || { echo "Invalid Zstd level: $level" >&2; exit 2; }
  sudo rm -rf "$WORK_ROOT/data"
  sudo cp -a --reflink=never "$SOURCE" "$WORK_ROOT/data"
  sync
  start="$(date +%s%N)"
  sudo btrfs filesystem defragment -r -czstd -L "$level" "$WORK_ROOT/data" >/dev/null
  sync
  end="$(date +%s%N)"
  elapsed_ms=$(( (end - start) / 1000000 ))
  printf '%-12s %-14s\n' "$level" "$elapsed_ms"
  sudo compsize "$WORK_ROOT/data"
  echo
done
