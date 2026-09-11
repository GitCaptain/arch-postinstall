#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="${1:-}"
[[ "$NAME" =~ ^[a-zA-Z0-9._-]+$ ]] || { echo "Usage: $0 MODULE_NAME" >&2; exit 2; }
DIR="$REPO_ROOT/modules/$NAME"
[[ ! -e "$DIR" ]] || { echo "Module already exists: $DIR" >&2; exit 1; }
mkdir -p "$DIR"
cat > "$DIR/packages.txt" <<'PKGS'
# One official Arch package per line.
PKGS
cat > "$DIR/configure.sh" <<'CONFIG'
#!/usr/bin/env bash
set -Eeuo pipefail
ACTION="${1:-apply}"
plan() { echo '  - no configuration actions yet'; }
apply() { :; }
case "$ACTION" in
  plan) plan ;;
  apply) apply ;;
  *) echo "Unknown action: $ACTION" >&2; exit 2 ;;
esac
CONFIG
chmod +x "$DIR/configure.sh"
echo "Created module: $DIR"
