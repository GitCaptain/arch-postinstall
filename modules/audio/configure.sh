#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-apply}"

plan() {
  cat <<'PLAN'
  - install PipeWire audio stack separately from the GUI module
  - PipeWire/WirePlumber use systemd user units and socket activation
  - provide ALSA and PulseAudio compatibility through PipeWire
  - no JACK or gaming/multilib packages are installed here
PLAN
}

apply() {
  printf 'PipeWire audio packages installed for %s.\n' "$TARGET_USER"
  printf 'They will start through systemd user/socket activation after login.\n'
}

case "$ACTION" in
  plan) plan ;;
  apply) apply ;;
  *) echo "Unknown action: $ACTION" >&2; exit 2 ;;
esac
