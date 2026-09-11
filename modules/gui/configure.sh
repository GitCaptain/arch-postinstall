#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-apply}"
SOURCE_CONFIG="$REPO_ROOT/modules/gui/files/hyprland.conf"
TARGET_CONFIG="$TARGET_HOME/.config/hypr/hyprland.conf"

plan() {
  cat <<PLAN
  - install repository Hyprland config:
      $SOURCE_CONFIG
      -> $TARGET_CONFIG
  - preserve an existing config once as:
      $TARGET_CONFIG.pre-arch-setup
  - no display manager is configured
  - start Hyprland manually from a local TTY with: start-hyprland
  - GPU-specific drivers are intentionally not guessed here; use a separate module
PLAN
}

apply() {
  [[ -f "$SOURCE_CONFIG" ]] || { echo "Missing $SOURCE_CONFIG" >&2; exit 1; }
  sudo -u "$TARGET_USER" mkdir -p "$TARGET_HOME/.config/hypr"

  if [[ -e "$TARGET_CONFIG" && ! -e "${TARGET_CONFIG}.pre-arch-setup" ]]; then
    sudo -u "$TARGET_USER" cp -a "$TARGET_CONFIG" "${TARGET_CONFIG}.pre-arch-setup"
  fi

  sudo install -m 644 -o "$TARGET_USER" -g "$TARGET_USER" "$SOURCE_CONFIG" "$TARGET_CONFIG"
  printf 'Hyprland config installed for %s.\n' "$TARGET_USER"
  printf 'Launch from a LOCAL TTY as that user with: start-hyprland\n'
}

case "$ACTION" in
  plan) plan ;;
  apply) apply ;;
  *) echo "Unknown action: $ACTION" >&2; exit 2 ;;
esac
