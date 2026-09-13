#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-apply}"
SSH_DROPIN="/etc/ssh/sshd_config.d/20-arch-setup.conf"
BUNDLED_KEYS="$REPO_ROOT/assets/authorized_keys"

target_group() {
  id -gn "$TARGET_USER"
}

plan() {
  cat <<PLAN
  - enable/start NetworkManager
  - bootstrap yay AUR helper if it is not installed
    (build as $TARGET_USER; never run makepkg as root)
  - configure OpenSSH server
  - PermitRootLogin no
  - PubkeyAuthentication yes
  - install bundled public authorized_keys if assets/authorized_keys exists
  - disable SSH password/keyboard-interactive login only when $TARGET_USER has authorized_keys
  - validate sshd config
  - enable/start sshd
PLAN
}

install_yay() {
  if command -v yay >/dev/null 2>&1; then
    printf 'yay already installed: %s\n' "$(command -v yay)"
    return 0
  fi

  local installed_go=0 build_root pkg

  if ! pacman -Qq go >/dev/null 2>&1; then
    sudo pacman -S --needed --noconfirm go
    installed_go=1
  fi

  build_root="$(mktemp -d /tmp/arch-postinstall-yay.XXXXXX)"
  sudo chown "$TARGET_USER:$(target_group)" "$build_root"

  sudo -u "$TARGET_USER" env HOME="$TARGET_HOME" \
    git clone --depth 1 https://aur.archlinux.org/yay.git "$build_root/yay"

  sudo -u "$TARGET_USER" env HOME="$TARGET_HOME" \
    bash -c 'cd "$1" && makepkg --noconfirm' _ "$build_root/yay"

  pkg="$(find "$build_root/yay" -maxdepth 1 -type f \
    -name 'yay-[0-9]*.pkg.tar.*' ! -name '*.sig' -print -quit)"

  [[ -n "$pkg" ]] || {
    rm -rf "$build_root"
    echo "Could not locate the built yay package." >&2
    exit 1
  }

  sudo pacman -U --needed --noconfirm "$pkg"
  rm -rf "$build_root"

  if ((installed_go)); then
    sudo pacman -Rns --noconfirm go || \
      printf 'WARN: temporary Go package was left installed; remove it manually if desired.\n' >&2
  fi
}

install_authorized_keys() {
  [[ -s "$BUNDLED_KEYS" ]] || return 0
  sudo install -d -m 700 -o "$TARGET_USER" -g "$(target_group)" "$TARGET_HOME/.ssh"

  local tmp
  tmp="$(mktemp)"
  {
    [[ -f "$TARGET_HOME/.ssh/authorized_keys" ]] && cat "$TARGET_HOME/.ssh/authorized_keys"
    cat "$BUNDLED_KEYS"
  } | awk 'NF && !seen[$0]++' > "$tmp"

  sudo install -m 600 -o "$TARGET_USER" -g "$(target_group)" \
    "$tmp" "$TARGET_HOME/.ssh/authorized_keys"
  rm -f "$tmp"
}

apply() {
  sudo systemctl enable --now NetworkManager
  install_yay
  install_authorized_keys

  sudo install -d -m 755 /etc/ssh/sshd_config.d

  local password_auth="yes" kbd_auth="yes"
  if sudo -u "$TARGET_USER" test -s "$TARGET_HOME/.ssh/authorized_keys"; then
    password_auth="no"
    kbd_auth="no"
  fi

  sudo tee "$SSH_DROPIN" >/dev/null <<CONFIG
# Managed by arch-postinstall/modules/base/configure.sh
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication $password_auth
KbdInteractiveAuthentication $kbd_auth
CONFIG

  sudo chmod 600 "$SSH_DROPIN"
  sudo sshd -t
  sudo systemctl enable --now sshd

  if [[ "$password_auth" == "yes" ]]; then
    printf 'WARN: no authorized_keys found for %s; SSH password login remains enabled.\n' \
      "$TARGET_USER" >&2
  fi
}

case "$ACTION" in
  plan) plan ;;
  apply) apply ;;
  *) echo "Unknown action: $ACTION" >&2; exit 2 ;;
esac
