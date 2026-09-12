#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-apply}"
SOURCE_DIR="$REPO_ROOT/modules/gui/files"
TARGET_DIR="$TARGET_HOME/.config/hypr"

plan() {
  cat <<PLAN
  - auto-detect all PCI GPUs before package installation
  - AMD/Intel: install Mesa userspace graphics driver
  - NVIDIA: install the current nvidia-open kernel-module stack + nvidia-utils
    (Turing/GTX 16xx/RTX or newer; old NVIDIA requires a manual legacy path)
  - hybrid AMD/Intel + NVIDIA installs drivers for BOTH GPUs
  - install minimal Hyprland config using Ghostty
  - no Waybar, launcher, notification daemon or wallpaper daemon
  - install hyprlock + hypridle configuration
  - SUPER+L locks the session
  - idle: lock at 5 min, display off at 5.5 min, suspend at 30 min
  - preserve each existing config once as *.pre-arch-setup
  - no display manager is configured
  - launch from a local TTY with: start-hyprland
PLAN
}

install_user_config() {
  local name="$1" source="$SOURCE_DIR/$name" target="$TARGET_DIR/$name"
  [[ -f "$source" ]] || { echo "Missing $source" >&2; exit 1; }

  if [[ -e "$target" && ! -e "${target}.pre-arch-setup" ]]; then
    sudo -u "$TARGET_USER" cp -a "$target" "${target}.pre-arch-setup"
  fi

  sudo install -m 644 -o "$TARGET_USER" -g "$TARGET_USER" "$source" "$target"
}

apply() {
  sudo -u "$TARGET_USER" mkdir -p "$TARGET_DIR"

  install_user_config hyprland.conf
  install_user_config hypridle.conf
  install_user_config hyprlock.conf

  printf 'Minimal Hyprland configuration installed for %s.\n' "$TARGET_USER"
  printf 'Launch from a LOCAL TTY as that user with: start-hyprland\n'
  printf 'A reboot is recommended after installing/changing NVIDIA kernel modules.\n'
}

case "$ACTION" in
  plan) plan ;;
  apply) apply ;;
  *) echo "Unknown action: $ACTION" >&2; exit 2 ;;
esac
