#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO_ROOT/modules/base/packages.txt"
COPY_KEYS=0
USER_NAME="${SUDO_USER:-$(id -un)}"

usage() {
  cat <<'HELP'
Usage:
  ./scripts/capture-current-base.sh [--copy-authorized-keys] [--user USER]

Run this on the current/source Arch installation BEFORE adding GUI/extra modules.
It writes explicitly-installed official-repository packages to:
  modules/base/packages.txt

Options:
  --copy-authorized-keys   Copy USER's authorized_keys to assets/authorized_keys.
                           Only public keys are copied; no private SSH keys.
  --user USER              User whose authorized_keys should be copied.
HELP
}

while (($#)); do
  case "$1" in
    --copy-authorized-keys) COPY_KEYS=1; shift ;;
    --user) (($# >= 2)) || { echo "--user requires a value" >&2; exit 2; }; USER_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v pacman >/dev/null || { echo "pacman not found; run this on Arch Linux." >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
pacman -Qqen | sort -u > "$tmp"

for pkg in sudo openssh git; do
  grep -qxF "$pkg" "$tmp" || echo "$pkg" >> "$tmp"
done

{
  echo "# Captured from source machine on $(date -Iseconds)"
  echo "# Explicit packages from official Arch repositories."
  sort -u "$tmp"
} > "$OUT"

echo "Wrote: $OUT"
echo "Packages: $(grep -cvE '^[[:space:]]*(#|$)' "$OUT")"

if ((COPY_KEYS)); then
  home="$(getent passwd "$USER_NAME" | cut -d: -f6)"
  [[ -n "$home" ]] || { echo "Could not resolve home for $USER_NAME" >&2; exit 1; }
  src="$home/.ssh/authorized_keys"
  if [[ -s "$src" ]]; then
    mkdir -p "$REPO_ROOT/assets"
    cp "$src" "$REPO_ROOT/assets/authorized_keys"
    chmod 644 "$REPO_ROOT/assets/authorized_keys"
    echo "Copied public authorized_keys -> $REPO_ROOT/assets/authorized_keys"
  else
    echo "No authorized_keys found for $USER_NAME; nothing copied." >&2
  fi
fi
