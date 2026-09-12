#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-packages}"

cpu_vendor() {
  awk -F: '/^[[:space:]]*vendor_id[[:space:]]*:/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' /proc/cpuinfo
}

vendor="${ARCH_SETUP_CPU_VENDOR:-$(cpu_vendor)}"
[[ -n "$vendor" ]] || { echo "Could not determine CPU vendor from /proc/cpuinfo." >&2; exit 1; }

case "$vendor" in
  AuthenticAMD)
    label="AMD"
    package="amd-ucode"
    ;;
  GenuineIntel)
    label="Intel"
    package="intel-ucode"
    ;;
  *)
    echo "Unsupported CPU vendor '$vendor'. Install the correct microcode/firmware manually and extend modules/base/detect-packages.sh." >&2
    exit 1
    ;;
esac

case "$ACTION" in
  packages)
    printf '%s\n' "$package"
    ;;
  describe)
    printf 'CPU: %s (%s) -> %s\n' "$label" "$vendor" "$package"
    ;;
  *)
    echo "Unknown action: $ACTION" >&2
    exit 2
    ;;
esac
