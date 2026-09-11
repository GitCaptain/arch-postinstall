#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-apply}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

plan() {
  cat <<PLAN
  - require / to be Btrfs
  - set the / fstab entry to compress=$BTRFS_COMPRESSION
  - remount / with compress=$BTRFS_COMPRESSION
  - create/reuse top-level @swap subvolume mounted at /swap
  - create $SWAP_SIZE /swap/swapfile via btrfs filesystem mkswapfile
    (preallocation + NOCOW are handled by mkswapfile)
  - add /swap and swapfile entries to /etc/fstab
  - configure Snapper snapshots for /
  - reuse a separately-mounted /.snapshots Btrfs subvolume if one already exists
  - configure timeline retention: 5 hourly, 7 daily, 4 weekly, 6 monthly
  - enable snapper-timeline.timer and snapper-cleanup.timer
  - snap-pac provides pacman pre/post snapshots
PLAN
}

require_btrfs_root() {
  local fs
  fs="$(findmnt -no FSTYPE /)"
  [[ "$fs" == "btrfs" ]] || die "Root filesystem is '$fs', not btrfs."
}

validate_compression() {
  [[ "$BTRFS_COMPRESSION" =~ ^(zstd(:-?[0-9]+)?|zlib(:[1-9])?|lzo|no)$ ]] || \
    die "Unsupported compression value: $BTRFS_COMPRESSION"
}

backup_fstab_once() {
  [[ -e /etc/fstab.pre-arch-setup ]] || sudo cp -a /etc/fstab /etc/fstab.pre-arch-setup
}

set_root_compression() {
  validate_compression
  backup_fstab_once

  local tmp
  tmp="$(mktemp)"
  awk -v compression="$BTRFS_COMPRESSION" '
    BEGIN { OFS="\t"; changed=0 }
    /^[[:space:]]*#/ || NF < 4 { print; next }
    $2 == "/" && $3 == "btrfs" {
      n = split($4, opts, ",")
      out = ""
      for (i = 1; i <= n; i++) {
        if (opts[i] ~ /^compress(-force)?=/) continue
        if (opts[i] == "") continue
        out = (out == "" ? opts[i] : out "," opts[i])
      }
      out = (out == "" ? "compress=" compression : out ",compress=" compression)
      $4 = out
      changed=1
    }
    { print }
    END {
      if (!changed) {
        print "No Btrfs root entry found in /etc/fstab" > "/dev/stderr"
        exit 42
      }
    }
  ' /etc/fstab > "$tmp" || {
    rm -f "$tmp"
    die "Could not update Btrfs root entry in /etc/fstab."
  }

  sudo install -m 644 "$tmp" /etc/fstab
  rm -f "$tmp"
  log "Remounting / with compress=$BTRFS_COMPRESSION"
  sudo mount -o "remount,compress=$BTRFS_COMPRESSION" /
}

root_device() {
  findmnt -no SOURCE / | sed -E 's/\[.*$//'
}

root_uuid() {
  findmnt -no UUID /
}

ensure_swap_subvolume_mount() {
  local dev uuid top
  dev="$(root_device)"
  uuid="$(root_uuid)"
  top="/run/arch-setup-btrfs-top"

  sudo mkdir -p /swap
  mountpoint -q /swap && return 0

  sudo mkdir -p "$top"
  sudo mount -t btrfs -o subvolid=5 "$dev" "$top"

  if ! sudo btrfs subvolume show "$top/@swap" &>/dev/null; then
    log "Creating top-level Btrfs subvolume @swap"
    sudo btrfs subvolume create "$top/@swap"
  fi

  sudo umount "$top"
  sudo rmdir "$top" 2>/dev/null || true

  if ! awk '$2 == "/swap" && $3 == "btrfs" { found=1 } END { exit !found }' /etc/fstab; then
    backup_fstab_once
    printf 'UUID=%s\t/swap\tbtrfs\tsubvol=@swap,noatime\t0\t0\n' "$uuid" | sudo tee -a /etc/fstab >/dev/null
  fi

  sudo mount /swap
}

ensure_swapfile() {
  ensure_swap_subvolume_mount

  if [[ ! -e /swap/swapfile ]]; then
    log "Creating Btrfs swapfile: $SWAP_SIZE"
    sudo btrfs filesystem mkswapfile --size "$SWAP_SIZE" --uuid clear /swap/swapfile
  fi

  sudo chmod 600 /swap/swapfile

  if ! grep -Eq '^[^#]+[[:space:]]+/swap/swapfile[[:space:]]+none[[:space:]]+swap([[:space:],]|$)' /etc/fstab; then
    backup_fstab_once
    printf '/swap/swapfile\tnone\tswap\tdefaults\t0\t0\n' | sudo tee -a /etc/fstab >/dev/null
  fi

  if ! swapon --noheadings --show=NAME | grep -qx '/swap/swapfile'; then
    sudo swapon /swap/swapfile
  fi
}

adapt_existing_snapshots_mount_for_snapper() {
  if ! awk '$2 == "/.snapshots" && $3 == "btrfs" { found=1 } END { exit !found }' /etc/fstab; then
    die "/.snapshots is mounted, but no Btrfs /.snapshots entry exists in /etc/fstab."
  fi

  log "Adapting existing /.snapshots mount for Snapper"
  sudo umount /.snapshots
  sudo rmdir /.snapshots
  sudo snapper -c root create-config /

  # Snapper created a nested /.snapshots subvolume. Remove it and mount the
  # already-existing dedicated snapshot subvolume back in its place.
  sudo btrfs subvolume delete /.snapshots
  sudo mkdir -p /.snapshots
  sudo mount /.snapshots
  sudo chmod 750 /.snapshots
}

ensure_snapper_root_config() {
  if [[ -f /etc/snapper/configs/root ]]; then
    log "Snapper root config already exists"
  else
    if mountpoint -q /.snapshots; then
      adapt_existing_snapshots_mount_for_snapper
    else
      if [[ -e /.snapshots ]]; then
        if sudo btrfs subvolume show /.snapshots &>/dev/null; then
          die "/.snapshots already exists as an unmounted Btrfs subvolume; inspect it before running this module."
        elif [[ -d /.snapshots ]] && [[ -z "$(sudo find /.snapshots -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
          sudo rmdir /.snapshots
        else
          die "/.snapshots exists and is not an empty directory."
        fi
      fi
      sudo snapper -c root create-config /
      sudo chmod 750 /.snapshots
    fi
  fi

  local cfg="/etc/snapper/configs/root"
  sudo sed -Ei \
    -e 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="yes"/' \
    -e 's/^TIMELINE_CLEANUP=.*/TIMELINE_CLEANUP="yes"/' \
    -e 's/^TIMELINE_MIN_AGE=.*/TIMELINE_MIN_AGE="1800"/' \
    -e 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/' \
    -e 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' \
    -e 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="4"/' \
    -e 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="6"/' \
    -e 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' \
    "$cfg"

  sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer

  if ! sudo snapper -c root list | grep -Fq 'arch-setup initial'; then
    sudo snapper -c root create -d "arch-setup initial"
  fi
}

apply() {
  require_btrfs_root
  set_root_compression
  ensure_swapfile
  ensure_snapper_root_config

  log "Btrfs setup complete"
  findmnt -no SOURCE,FSTYPE,OPTIONS /
  swapon --show
  sudo snapper -c root list
}

case "$ACTION" in
  plan) plan ;;
  apply) apply ;;
  *) echo "Unknown action: $ACTION" >&2; exit 2 ;;
esac
