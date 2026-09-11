#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULES=("base")
DRY_RUN=0
TARGET_USER=""
BTRFS_COMPRESSION="zstd:3"
SWAP_SIZE="8G"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'HELP'
Usage:
  ./setup-arch.sh [options]

Base is always enabled.

Options:
  --module NAME               Enable an additional module (repeatable).
  --dry-run                   Show package/configuration plan without changing anything.
  --user USER                 User whose desktop/config files should be configured.
  --btrfs-compression VALUE   Compression for btrfs module (default: zstd:3).
                              Examples: zstd:1, zstd:3, zstd:-3
  --swap-size SIZE            Swapfile size for btrfs module (default: 8G).
  -h, --help                  Show this help.

Examples:
  ./setup-arch.sh --dry-run --module btrfs --module gui
  ./setup-arch.sh --module btrfs --btrfs-compression zstd:3 --swap-size 16G
  ./setup-arch.sh --module gui
HELP
}

add_module() {
  local candidate="$1" module
  for module in "${MODULES[@]}"; do
    [[ "$module" == "$candidate" ]] && return 0
  done
  MODULES+=("$candidate")
}

while (($#)); do
  case "$1" in
    --module) (($# >= 2)) || die "--module requires a value"; add_module "$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --user) (($# >= 2)) || die "--user requires a value"; TARGET_USER="$2"; shift 2 ;;
    --btrfs-compression) (($# >= 2)) || die "--btrfs-compression requires a value"; BTRFS_COMPRESSION="$2"; shift 2 ;;
    --swap-size) (($# >= 2)) || die "--swap-size requires a value"; SWAP_SIZE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

command -v pacman >/dev/null || die "pacman not found; this installer is for Arch Linux."

if [[ -z "$TARGET_USER" ]]; then
  if [[ $EUID -eq 0 ]]; then
    TARGET_USER="${SUDO_USER:-}"
    [[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]] || die "Run as your normal user or pass --user USER."
  else
    TARGET_USER="$(id -un)"
  fi
fi

id "$TARGET_USER" &>/dev/null || die "User '$TARGET_USER' does not exist."
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" ]] || die "Could not resolve home directory for '$TARGET_USER'."

export REPO_ROOT TARGET_USER TARGET_HOME BTRFS_COMPRESSION SWAP_SIZE

read_packages() {
  sed -E \
    -e 's/[[:space:]]*#.*$//' \
    -e '/^[[:space:]]*$/d' \
    -e 's/^[[:space:]]+//' \
    -e 's/[[:space:]]+$//' \
    "$1"
}

validate_modules() {
  local module dir
  for module in "${MODULES[@]}"; do
    dir="$REPO_ROOT/modules/$module"
    [[ -d "$dir" ]] || die "Unknown module '$module' (missing $dir)"
    [[ -f "$dir/packages.txt" ]] || die "Module '$module' has no packages.txt"
    [[ -x "$dir/configure.sh" ]] || die "Module '$module' has no executable configure.sh"
  done
}

collect_packages() {
  local module pkg
  local -a all=()
  for module in "${MODULES[@]}"; do
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] && all+=("$pkg")
    done < <(read_packages "$REPO_ROOT/modules/$module/packages.txt")
  done
  ((${#all[@]})) && printf '%s\n' "${all[@]}" | sort -u
}

show_package_plan() {
  local module pkg status
  for module in "${MODULES[@]}"; do
    printf '\n[%s packages]\n' "$module"
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue
      if pacman -Qq "$pkg" &>/dev/null; then status="installed"; else status="INSTALL"; fi
      printf '  %-11s %s\n' "[$status]" "$pkg"
    done < <(read_packages "$REPO_ROOT/modules/$module/packages.txt")
  done
}

show_config_plan() {
  local module
  for module in "${MODULES[@]}"; do
    printf '\n[%s configuration]\n' "$module"
    "$REPO_ROOT/modules/$module/configure.sh" plan
  done
}

validate_modules
mapfile -t PACKAGES < <(collect_packages)

log "Target user: $TARGET_USER"
log "Modules: ${MODULES[*]}"

if ((DRY_RUN)); then
  printf '\nDRY RUN — no files, packages, mounts or services will be changed.\n'
  printf 'Btrfs compression: %s\n' "$BTRFS_COMPRESSION"
  printf 'Swap size: %s\n' "$SWAP_SIZE"
  show_package_plan
  show_config_plan

  missing=0
  for pkg in "${PACKAGES[@]}"; do
    pacman -Qq "$pkg" &>/dev/null || ((missing+=1))
  done
  printf '\n[summary]\n'
  printf '  selected modules: %s\n' "${MODULES[*]}"
  printf '  unique packages in manifests: %d\n' "${#PACKAGES[@]}"
  printf '  packages that would be installed: %d\n' "$missing"
  exit 0
fi

if ((${#PACKAGES[@]})); then
  log "Updating system and installing manifest packages"
  sudo pacman -Syu --needed -- "${PACKAGES[@]}"
else
  log "No manifest packages; updating system only"
  sudo pacman -Syu
fi

for module in "${MODULES[@]}"; do
  log "Configuring module '$module'"
  "$REPO_ROOT/modules/$module/configure.sh" apply
done

log "Done."
