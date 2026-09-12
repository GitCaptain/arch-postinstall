#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-apply}"
SSH_DROPIN="/etc/ssh/sshd_config.d/20-arch-setup.conf"
BUNDLED_KEYS="$REPO_ROOT/assets/authorized_keys"

plan() {
  cat <<PLAN
  - enable/start NetworkManager
  - configure OpenSSH server
  - PermitRootLogin no
  - PubkeyAuthentication yes
  - install bundled public authorized_keys if assets/authorized_keys exists
  - disable SSH password/keyboard-interactive login only when $TARGET_USER has authorized_keys
  - validate sshd config
  - enable/start sshd
PLAN
}

install_authorized_keys() {
  [[ -s "$BUNDLED_KEYS" ]] || return 0
  sudo install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.ssh"

  local tmp
  tmp="$(mktemp)"
  {
    [[ -f "$TARGET_HOME/.ssh/authorized_keys" ]] && cat "$TARGET_HOME/.ssh/authorized_keys"
    cat "$BUNDLED_KEYS"
  } | awk 'NF && !seen[$0]++' > "$tmp"

  sudo install -m 600 -o "$TARGET_USER" -g "$TARGET_USER" "$tmp" "$TARGET_HOME/.ssh/authorized_keys"
  rm -f "$tmp"
}

apply() {
  sudo systemctl enable --now NetworkManager
  install_authorized_keys
  sudo install -d -m 755 /etc/ssh/sshd_config.d

  local password_auth="yes" kbd_auth="yes"
  if sudo -u "$TARGET_USER" test -s "$TARGET_HOME/.ssh/authorized_keys"; then
    password_auth="no"
    kbd_auth="no"
  fi

  sudo tee "$SSH_DROPIN" >/dev/null <<CONFIG
# Managed by arch-setup/modules/base/configure.sh
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication $password_auth
KbdInteractiveAuthentication $kbd_auth
CONFIG
  sudo chmod 600 "$SSH_DROPIN"
  sudo sshd -t
  sudo systemctl enable --now sshd

  if [[ "$password_auth" == "yes" ]]; then
    printf 'WARN: no authorized_keys found for %s; SSH password login remains enabled.\n' "$TARGET_USER" >&2
  fi
}

case "$ACTION" in
  plan) plan ;;
  apply) apply ;;
  *) echo "Unknown action: $ACTION" >&2; exit 2 ;;
esac
