#!/usr/bin/env bash
set -Eeuo pipefail

# setup-arch.sh
#
# Modular Arch Linux bootstrap for an already installed system.
# Base is always enabled. Other modules are selected with:
#   ./setup-arch.sh --module btrfs --module gui
#
# Package manifests live next to this script:
#   modules/base.packages
#   modules/btrfs.packages
#   modules/gui.packages
#
# Any additional modules/*.packages file works automatically as a
# package-only module. Add a hook function below only when a module
# needs configuration in addition to package installation.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$SCRIPT_DIR/modules"

TARGET_USER=""
SWAP_SIZE="8G"
ZSTD_LEVEL="3"
BENCH_PATH=""
CAPTURE_BASE=0
MODULES=("base")

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  ./setup-arch.sh [options]

Options:
  --module NAME          Enable module (repeatable). "base" is always enabled.
                         Built-in configured modules: base, btrfs, gui.
                         Any modules/NAME.packages file is also accepted.
  --user USER            Desktop/login user to configure. Defaults to the user
                         running the script (or SUDO_USER when run as root).
  --swap-size SIZE       Btrfs swapfile size, default: 8G.
  --zstd-level LEVEL     Btrfs compression level, default: 3.
  --bench PATH           Benchmark zstd levels 1,3,5,8 on a copy of PATH.
                         Example: --bench /usr/bin
  --capture-base         Snapshot currently explicitly-installed repo packages
                         into modules/base.packages, then exit.
  -h, --help             Show help.

Examples:
  ./setup-arch.sh --capture-base
  ./setup-arch.sh --module btrfs --module gui
  ./setup-arch.sh --module btrfs --zstd-level 1 --swap-size 16G
  ./setup-arch.sh --module btrfs --bench /usr/bin
EOF
}

add_module() {
  local module="$1"
  local existing
  for existing in "${MODULES[@]}"; do
    [[ "$existing" == "$module" ]] && return 0
  done
  MODULES+=("$module")
}

while (($#)); do
  case "$1" in
    --module)
      (($# >= 2)) || die "--module requires an argument"
      add_module "$2"
      shift 2
      ;;
    --user)
      (($# >= 2)) || die "--user requires an argument"
      TARGET_USER="$2"
      shift 2
      ;;
    --swap-size)
      (($# >= 2)) || die "--swap-size requires an argument"
      SWAP_SIZE="$2"
      shift 2
      ;;
    --zstd-level)
      (($# >= 2)) || die "--zstd-level requires an argument"
      ZSTD_LEVEL="$2"
      shift 2
      ;;
    --bench)
      (($# >= 2)) || die "--bench requires a path"
      BENCH_PATH="$2"
      shift 2
      ;;
    --capture-base)
      CAPTURE_BASE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

if [[ -z "$TARGET_USER" ]]; then
  if [[ $EUID -eq 0 ]]; then
    TARGET_USER="${SUDO_USER:-}"
    [[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]] ||
      die "Run as your normal user, or pass --user USER."
  else
    TARGET_USER="$(id -un)"
  fi
fi

id "$TARGET_USER" &>/dev/null || die "User '$TARGET_USER' does not exist."
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" ]] || die "Cannot resolve home directory for '$TARGET_USER'."

sudo_keepalive() {
  sudo -v
  while true; do
    sudo -n true
    sleep 50
    kill -0 "$$" 2>/dev/null || exit
  done 2>/dev/null &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
}

mkdir -p "$MODULE_DIR"

capture_base() {
  log "Capturing explicitly-installed official-repo packages"
  {
    echo "# Captured on $(date -Iseconds)"
    echo "# Explicit native packages only (pacman -Qqen)"
    pacman -Qqen | sort -u
  } > "$MODULE_DIR/base.packages"
  log "Wrote $MODULE_DIR/base.packages"
}

if ((CAPTURE_BASE)); then
  capture_base
  exit 0
fi

sudo_keepalive

ensure_builtin_manifests() {
  if [[ ! -f "$MODULE_DIR/base.packages" ]]; then
    cat > "$MODULE_DIR/base.packages" <<'EOF'
# Minimal fallback base.
# On the source machine, run ./setup-arch.sh --capture-base BEFORE installing GUI
# to replace this with the exact explicit package set from your installation.
base
linux
linux-firmware
sudo
openssh
git
curl
nano
EOF
  fi

  if [[ ! -f "$MODULE_DIR/btrfs.packages" ]]; then
    cat > "$MODULE_DIR/btrfs.packages" <<'EOF'
btrfs-progs
snapper
snap-pac
compsize
EOF
  fi

  if [[ ! -f "$MODULE_DIR/gui.packages" ]]; then
    cat > "$MODULE_DIR/gui.packages" <<'EOF'
# Hyprland + a minimal usable Wayland desktop.
hyprland
xorg-xwayland
kitty
waybar
fuzzel
mako
hyprpaper
hyprlock
hypridle
hyprpolkitagent
xdg-desktop-portal
xdg-desktop-portal-hyprland
xdg-desktop-portal-gtk
pipewire
pipewire-audio
pipewire-pulse
wireplumber
qt5-wayland
qt6-wayland
mesa
vulkan-icd-loader
wl-clipboard
grim
slurp
brightnessctl
playerctl
noto-fonts
noto-fonts-emoji
ttf-jetbrains-mono-nerd
pciutils
EOF
  fi
}

read_manifest() {
  local file="$1"
  sed -E \
    -e 's/[[:space:]]*#.*$//' \
    -e '/^[[:space:]]*$/d' \
    -e 's/^[[:space:]]+//' \
    -e 's/[[:space:]]+$//' \
    "$file"
}

install_packages_for_module() {
  local module="$1"
  local file="$MODULE_DIR/$module.packages"
  [[ -f "$file" ]] || die "No package manifest for module '$module': $file"

  mapfile -t packages < <(read_manifest "$file")
  if ((${#packages[@]})); then
    log "Installing packages for module '$module'"
    sudo pacman -S --needed --noconfirm "${packages[@]}"
  fi
}

backup_file_once() {
  local file="$1"
  local backup="${file}.pre-arch-setup"
  if [[ -e "$file" && ! -e "$backup" ]]; then
    sudo cp -a "$file" "$backup"
    log "Backup: $backup"
  fi
}

set_sshd_option() {
  local key="$1"
  local value="$2"
  local file="/etc/ssh/sshd_config.d/10-arch-setup.conf"
  sudo mkdir -p /etc/ssh/sshd_config.d
  sudo touch "$file"
  sudo chmod 600 "$file"

  if sudo grep -Eq "^[[:space:]]*${key}[[:space:]]+" "$file"; then
    sudo sed -Ei "s|^[[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" "$file"
  else
    printf '%s %s\n' "$key" "$value" | sudo tee -a "$file" >/dev/null
  fi
}

configure_base() {
  log "Configuring SSH"
  set_sshd_option PermitRootLogin no
  set_sshd_option PubkeyAuthentication yes

  # Only disable passwords automatically when the target user already has a key.
  if sudo -u "$TARGET_USER" test -s "$TARGET_HOME/.ssh/authorized_keys"; then
    set_sshd_option PasswordAuthentication no
    log "authorized_keys exists: SSH password login disabled"
  else
    warn "No authorized_keys for $TARGET_USER; keeping password login unchanged."
  fi

  sudo sshd -t
  sudo systemctl enable --now sshd
}

require_btrfs_root() {
  local fs
  fs="$(findmnt -no FSTYPE /)"
  [[ "$fs" == "btrfs" ]] || die "Root filesystem is '$fs', not btrfs."
}

root_btrfs_device() {
  findmnt -no SOURCE / | sed -E 's/\[.*$//'
}

root_btrfs_uuid() {
  findmnt -no UUID /
}

set_root_compression_in_fstab() {
  local level="$1"
  local tmp
  tmp="$(mktemp)"
  backup_file_once /etc/fstab

  awk -v level="$level" '
    BEGIN { OFS="\t" }
    /^[[:space:]]*#/ || NF < 4 { print; next }
    $2 == "/" && $3 == "btrfs" {
      n = split($4, a, ",")
      out = ""
      for (i = 1; i <= n; i++) {
        if (a[i] ~ /^compress(-force)?=/) continue
        if (a[i] == "") continue
        out = (out == "" ? a[i] : out "," a[i])
      }
      out = (out == "" ? "compress=zstd:" level : out ",compress=zstd:" level)
      $4 = out
    }
    { print }
  ' /etc/fstab > "$tmp"

  sudo install -m 644 "$tmp" /etc/fstab
  rm -f "$tmp"

  log "Remounting / with compress=zstd:$level"
  sudo mount -o "remount,compress=zstd:$level" /
}

setup_swap_subvolume() {
  local dev uuid top
  dev="$(root_btrfs_device)"
  uuid="$(root_btrfs_uuid)"
  top="/run/arch-setup-btrfs-top"

  if swapon --noheadings --show=NAME | grep -qx '/swap/swapfile'; then
    log "Swapfile already active: /swap/swapfile"
    return 0
  fi

  if mountpoint -q /swap; then
    log "/swap is already a mountpoint; reusing it"
  elif sudo btrfs subvolume show /swap &>/dev/null; then
    log "/swap is already a Btrfs subvolume; reusing it"
  else
    if [[ -d /swap ]] && [[ -n "$(find /swap -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
      die "/swap exists and is not empty; refusing to overwrite it."
    fi

    sudo mkdir -p "$top"
    sudo mount -t btrfs -o subvolid=5 "$dev" "$top"

    if ! sudo btrfs subvolume show "$top/@swap" &>/dev/null; then
      log "Creating top-level @swap subvolume"
      sudo btrfs subvolume create "$top/@swap"
    fi

    sudo umount "$top"
    sudo rmdir "$top" 2>/dev/null || true
    sudo mkdir -p /swap

    if ! awk '$2 == "/swap" && $3 == "btrfs" { found=1 } END { exit !found }' /etc/fstab; then
      printf 'UUID=%s\t/swap\tbtrfs\tsubvol=@swap\t0\t0\n' "$uuid" |
        sudo tee -a /etc/fstab >/dev/null
    fi

    sudo mount /swap
  fi

  if [[ ! -e /swap/swapfile ]]; then
    log "Creating $SWAP_SIZE Btrfs NOCOW swapfile"
    sudo btrfs filesystem mkswapfile --size "$SWAP_SIZE" --uuid clear /swap/swapfile
  fi

  sudo chmod 600 /swap/swapfile

  if ! grep -Eq '^[^#]+[[:space:]]+/swap/swapfile[[:space:]]+none[[:space:]]+swap([[:space:],]|$)' /etc/fstab; then
    printf '/swap/swapfile\tnone\tswap\tdefaults\t0\t0\n' |
      sudo tee -a /etc/fstab >/dev/null
  fi

  sudo swapon /swap/swapfile 2>/dev/null || true
  swapon --show
}

setup_snapper_root() {
  local config="/etc/snapper/configs/root"

  if [[ ! -f "$config" ]]; then
    log "Creating Snapper config for /"

    if mountpoint -q /.snapshots; then
      if grep -Eq '^[^#]+[[:space:]]+/.snapshots[[:space:]]+btrfs([[:space:]]|$)' /etc/fstab; then
        log "Detected separately-mounted /.snapshots; adapting it for Snapper"
        sudo umount /.snapshots
        sudo rmdir /.snapshots
        sudo snapper -c root create-config /
        sudo btrfs subvolume delete /.snapshots
        sudo mkdir -p /.snapshots
        sudo mount /.snapshots
        sudo chmod 750 /.snapshots
      else
        die "/.snapshots is mounted but has no matching /etc/fstab entry; configure it manually."
      fi
    else
      if [[ -e /.snapshots ]]; then
        if sudo btrfs subvolume show /.snapshots &>/dev/null; then
          die "/.snapshots is already a Btrfs subvolume without a Snapper config; inspect it first."
        elif [[ -d /.snapshots ]] && [[ -z "$(sudo find /.snapshots -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
          sudo rmdir /.snapshots
        else
          die "/.snapshots already exists and is not an empty directory."
        fi
      fi
      sudo snapper -c root create-config /
    fi
  fi

  sudo chmod 750 /.snapshots

  log "Configuring snapshot retention"
  sudo sed -Ei \
    -e 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="yes"/' \
    -e 's/^TIMELINE_CLEANUP=.*/TIMELINE_CLEANUP="yes"/' \
    -e 's/^TIMELINE_MIN_AGE=.*/TIMELINE_MIN_AGE="1800"/' \
    -e 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/' \
    -e 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' \
    -e 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="4"/' \
    -e 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="6"/' \
    -e 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' \
    "$config"

  sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer

  if ! sudo snapper -c root list | grep -q 'arch-setup initial'; then
    sudo snapper -c root create -d "arch-setup initial"
  fi

  sudo snapper -c root list
}

benchmark_btrfs_compression() {
  local src="$1"
  local work="/var/tmp/btrfs-compression-bench"
  local level elapsed_start elapsed_end elapsed_ms
  local levels=(1 3 5 8)

  [[ -e "$src" ]] || die "Benchmark source does not exist: $src"
  require_btrfs_root

  warn "Benchmark copies '$src' up to four times sequentially. Use a representative, reasonably-sized path."
  sudo rm -rf "$work"
  sudo mkdir -p "$work"

  printf '\n%-8s %-14s\n' "zstd" "rewrite_ms"
  printf '%-8s %-14s\n' "-----" "----------"

  for level in "${levels[@]}"; do
    sudo rm -rf "$work/data"
    sudo cp -a --reflink=never "$src" "$work/data"
    sync

    elapsed_start="$(date +%s%N)"
    sudo btrfs filesystem defragment -r -czstd -L "$level" "$work/data" >/dev/null
    sync
    elapsed_end="$(date +%s%N)"
    elapsed_ms=$(( (elapsed_end - elapsed_start) / 1000000 ))

    printf '%-8s %-14s\n' "$level" "$elapsed_ms"
    sudo compsize "$work/data"
    echo
  done

  sudo rm -rf "$work"
  log "Benchmark complete. For a desktop/workstation, zstd:1 or zstd:3 is usually the useful comparison point."
}

configure_btrfs() {
  require_btrfs_root
  [[ "$ZSTD_LEVEL" =~ ^-?[0-9]+$ ]] || die "Invalid zstd level: $ZSTD_LEVEL"

  log "Current root mount:"
  findmnt -no SOURCE,FSTYPE,OPTIONS /

  set_root_compression_in_fstab "$ZSTD_LEVEL"
  setup_swap_subvolume
  setup_snapper_root

  if [[ -n "$BENCH_PATH" ]]; then
    benchmark_btrfs_compression "$BENCH_PATH"
  fi

  log "Btrfs status"
  sudo btrfs filesystem usage /
  findmnt -no SOURCE,FSTYPE,OPTIONS /
}

install_gpu_userspace() {
  local gpu
  gpu="$(lspci 2>/dev/null | grep -Ei 'VGA|3D|Display' || true)"

  if grep -qi 'NVIDIA' <<<"$gpu"; then
    warn "NVIDIA detected. Mesa is installed as a safe userspace fallback, but this script"
    warn "does NOT guess between nvidia-dkms / nvidia-open-dkms. Configure the NVIDIA"
    warn "driver as a separate module after checking the exact GPU generation."
  elif grep -Eqi 'AMD|ATI' <<<"$gpu"; then
    log "AMD GPU detected: installing Vulkan/VA-API userspace"
    sudo pacman -S --needed --noconfirm vulkan-radeon libva-mesa-driver
  elif grep -qi 'Intel' <<<"$gpu"; then
    log "Intel GPU detected: installing Vulkan/VA-API userspace"
    sudo pacman -S --needed --noconfirm vulkan-intel intel-media-driver
  else
    warn "GPU vendor not detected; keeping generic Mesa stack."
  fi
}

write_hyprland_config() {
  local cfg_dir="$TARGET_HOME/.config/hypr"
  local cfg="$cfg_dir/hyprland.conf"

  sudo -u "$TARGET_USER" mkdir -p "$cfg_dir"

  if [[ -e "$cfg" && ! -e "${cfg}.pre-arch-setup" ]]; then
    sudo -u "$TARGET_USER" cp -a "$cfg" "${cfg}.pre-arch-setup"
  fi

  cat <<'EOF' | sudo -u "$TARGET_USER" tee "$cfg" >/dev/null
# Minimal usable Hyprland config generated by setup-arch.sh.
# Customize this file and commit it as a dotfile later.

monitor = , preferred, auto, 1

$mod = SUPER

# Desktop services
exec-once = waybar
exec-once = mako
exec-once = systemctl --user start hyprpolkitagent.service

# Apps
bind = $mod, RETURN, exec, kitty
bind = $mod, D, exec, fuzzel
bind = $mod, Q, killactive,
bind = $mod SHIFT, E, exit,
bind = $mod, F, fullscreen, 1
bind = $mod, V, togglefloating,
bind = $mod SHIFT, S, exec, grim -g "$(slurp)" - | wl-copy

# Focus
bind = $mod, H, movefocus, l
bind = $mod, L, movefocus, r
bind = $mod, K, movefocus, u
bind = $mod, J, movefocus, d

# Workspaces
bind = $mod, 1, workspace, 1
bind = $mod, 2, workspace, 2
bind = $mod, 3, workspace, 3
bind = $mod, 4, workspace, 4
bind = $mod, 5, workspace, 5
bind = $mod SHIFT, 1, movetoworkspace, 1
bind = $mod SHIFT, 2, movetoworkspace, 2
bind = $mod SHIFT, 3, movetoworkspace, 3
bind = $mod SHIFT, 4, movetoworkspace, 4
bind = $mod SHIFT, 5, movetoworkspace, 5

# Mouse
bindm = $mod, mouse:272, movewindow
bindm = $mod, mouse:273, resizewindow

# Sensible defaults
input {
    kb_layout = us
    follow_mouse = 1
    touchpad {
        natural_scroll = true
    }
}

general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
}

decoration {
    rounding = 8
}
EOF

  sudo chown -R "$TARGET_USER:$TARGET_USER" "$cfg_dir"
}

configure_gui() {
  install_gpu_userspace
  write_hyprland_config

  # User services may not be available when provisioning from a root-only context;
  # start what we can, otherwise Hyprland autostart handles the polkit agent.
  if sudo -u "$TARGET_USER" systemctl --user is-system-running &>/dev/null; then
    sudo -u "$TARGET_USER" systemctl --user enable --now hyprpolkitagent.service 2>/dev/null || true
  fi

  log "GUI installed for user '$TARGET_USER'."
  log "From a LOCAL TTY as '$TARGET_USER', launch it with: start-hyprland"
}

run_hook() {
  case "$1" in
    base)  configure_base ;;
    btrfs) configure_btrfs ;;
    gui)   configure_gui ;;
    *)     log "Module '$1' has no configuration hook (packages only)." ;;
  esac
}

ensure_builtin_manifests

log "Target user: $TARGET_USER"
log "Modules: ${MODULES[*]}"

# Do one full upgrade before installing module packages.
sudo pacman -Syu --noconfirm

for module in "${MODULES[@]}"; do
  install_packages_for_module "$module"
  run_hook "$module"
done

log "Done."
