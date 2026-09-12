#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULES=("base")
DRY_RUN=0
TARGET_USER=""
BTRFS_COMPRESSION="zstd:-3"
SWAP_SIZE="8G"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'HELP'
Usage:
  ./setup-arch.sh [options]

Base is always enabled.

Options:
  --module NAME               Enable an additional module (repeatable).
  --dry-run                   Show packages, hardware detection and configuration plan.
  --user USER                 User whose desktop/config files should be configured.
  --btrfs-compression VALUE   Compression for btrfs module (default: zstd:-3).
  --swap-size SIZE            Swapfile size for btrfs module (default: 8G).
  -h, --help                  Show this help.

Examples:
  ./setup-arch.sh --dry-run --module btrfs --module gui --module audio
  ./setup-arch.sh --module btrfs --module gui --module audio \
    --btrfs-compression zstd:-3 --swap-size 16G
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
  local module dir detector
  for module in "${MODULES[@]}"; do
    dir="$REPO_ROOT/modules/$module"
    detector="$dir/detect-packages.sh"
    [[ -d "$dir" ]] || die "Unknown module '$module' (missing $dir)"
    [[ -f "$dir/packages.txt" ]] || die "Module '$module' has no packages.txt"
    [[ -x "$dir/configure.sh" ]] || die "Module '$module' has no executable configure.sh"
    [[ ! -e "$detector" || -x "$detector" ]] || die "$detector exists but is not executable"
  done
}

declare -A AUTO_PACKAGES=()
declare -A DETECTION_ERRORS=()
DETECTION_FAILED=0

run_hardware_detection() {
  local module detector out errfile error_text

  for module in "${MODULES[@]}"; do
    detector="$REPO_ROOT/modules/$module/detect-packages.sh"
    [[ -x "$detector" ]] || continue

    errfile="$(mktemp)"
    if out="$("$detector" packages 2>"$errfile")"; then
      AUTO_PACKAGES["$module"]="$out"
    else
      error_text="$(cat "$errfile")"
      DETECTION_ERRORS["$module"]="${error_text:-hardware detector failed without an error message}"
      DETECTION_FAILED=1
    fi
    rm -f "$errfile"
  done
}

module_packages() {
  local module="$1" static_file pkg
  static_file="$REPO_ROOT/modules/$module/packages.txt"

  {
    read_packages "$static_file"
    if [[ -n "${AUTO_PACKAGES[$module]:-}" ]]; then
      printf '%s\n' "${AUTO_PACKAGES[$module]}"
    fi
  } | awk 'NF && !seen[$0]++'
}

collect_packages() {
  local module pkg
  local -a all=()

  for module in "${MODULES[@]}"; do
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] && all+=("$pkg")
    done < <(module_packages "$module")
  done

  ((${#all[@]})) && printf '%s\n' "${all[@]}" | sort -u
}

show_hardware_plan() {
  local module detector
  printf '\n[hardware detection]\n'

  for module in "${MODULES[@]}"; do
    detector="$REPO_ROOT/modules/$module/detect-packages.sh"
    [[ -x "$detector" ]] || continue

    printf '  %s:\n' "$module"
    if [[ -n "${DETECTION_ERRORS[$module]:-}" ]]; then
      while IFS= read -r line; do
        printf '    ERROR: %s\n' "$line"
      done <<< "${DETECTION_ERRORS[$module]}"
    else
      "$detector" describe | sed 's/^/    /'
    fi
  done
}

show_package_plan() {
  local module pkg status
  for module in "${MODULES[@]}"; do
    printf '\n[%s packages]\n' "$module"
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue
      if pacman -Qq "$pkg" &>/dev/null; then status="installed"; else status="INSTALL"; fi
      printf '  %-11s %s\n' "[$status]" "$pkg"
    done < <(module_packages "$module")
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
run_hardware_detection
mapfile -t PACKAGES < <(collect_packages)

log "Target user: $TARGET_USER"
log "Modules: ${MODULES[*]}"

if ((DRY_RUN)); then
  printf '\nDRY RUN — no files, packages, mounts or services will be changed.\n'
  printf 'Btrfs compression: %s\n' "$BTRFS_COMPRESSION"
  printf 'Swap size: %s\n' "$SWAP_SIZE"

  show_hardware_plan
  show_package_plan
  show_config_plan

  missing=0
  for pkg in "${PACKAGES[@]}"; do
    pacman -Qq "$pkg" &>/dev/null || ((missing+=1))
  done

  printf '\n[summary]\n'
  printf '  selected modules: %s\n' "${MODULES[*]}"
  printf '  unique packages: %d\n' "${#PACKAGES[@]}"
  printf '  packages that would be installed: %d\n' "$missing"

  if ((DETECTION_FAILED)); then
    printf '  hardware detection: FAILED — see errors above\n' >&2
    exit 1
  fi

  printf '  hardware detection: OK\n'
  exit 0
fi

if ((DETECTION_FAILED)); then
  show_hardware_plan >&2
  die "Unsupported/unknown hardware detected. Refusing to install guessed drivers."
fi

if ((${#PACKAGES[@]})); then
  log "Updating system and installing packages"
  sudo pacman -Syu --needed -- "${PACKAGES[@]}"
else
  log "No packages selected; updating system only"
  sudo pacman -Syu
fi

for module in "${MODULES[@]}"; do
  log "Configuring module '$module'"
  "$REPO_ROOT/modules/$module/configure.sh" apply
done

log "Done."
