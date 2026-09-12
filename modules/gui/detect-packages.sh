#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-packages}"
PCI_ROOT="${ARCH_SETUP_PCI_ROOT:-/sys/bus/pci/devices}"
GPU_PRIMARY="${GPU_PRIMARY:-auto}"

case "$GPU_PRIMARY" in
  auto|nvidia|amd|intel) ;;
  *)
    echo "Invalid GPU_PRIMARY '$GPU_PRIMARY'; expected auto, nvidia, amd or intel." >&2
    exit 2
    ;;
esac

shopt -s nullglob
GPU_PATHS=()
AMD_PATHS=()
INTEL_PATHS=()
NVIDIA_PATHS=()
unknown=()

for path in "$PCI_ROOT"/*; do
  [[ -r "$path/class" && -r "$path/vendor" && -r "$path/device" ]] || continue
  class="$(<"$path/class")"
  [[ "$class" == 0x03* ]] || continue

  GPU_PATHS+=("$path")
  vendor="$(<"$path/vendor")"

  case "${vendor,,}" in
    0x1002) AMD_PATHS+=("$path") ;;
    0x8086) INTEL_PATHS+=("$path") ;;
    0x10de) NVIDIA_PATHS+=("$path") ;;
    *) unknown+=("${path##*/}: vendor=$vendor device=$(<"$path/device")") ;;
  esac
done

((${#GPU_PATHS[@]})) || {
  echo "No PCI display/3D controller was detected under $PCI_ROOT. Refusing to guess a GPU driver." >&2
  exit 1
}

if ((${#unknown[@]})); then
  printf 'Unsupported GPU vendor(s):\n' >&2
  printf '  %s\n' "${unknown[@]}" >&2
  printf 'Add an explicit driver rule to modules/gui/detect-packages.sh instead of guessing.\n' >&2
  exit 1
fi

has_amd=0
has_intel=0
has_nvidia=0
((${#AMD_PATHS[@]})) && has_amd=1
((${#INTEL_PATHS[@]})) && has_intel=1
((${#NVIDIA_PATHS[@]})) && has_nvidia=1

vendor_for_path() {
  case "${1}" in
    * )
      case "$(<"$1/vendor")" in
        0x1002|0X1002) printf 'amd\n' ;;
        0x8086|0X8086) printf 'intel\n' ;;
        0x10de|0X10DE) printf 'nvidia\n' ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

paths_for_vendor_count() {
  case "$1" in
    amd) printf '%s\n' "${#AMD_PATHS[@]}" ;;
    intel) printf '%s\n' "${#INTEL_PATHS[@]}" ;;
    nvidia) printf '%s\n' "${#NVIDIA_PATHS[@]}" ;;
    *) return 1 ;;
  esac
}

vendor_present() {
  case "$1" in
    amd) ((has_amd)) ;;
    intel) ((has_intel)) ;;
    nvidia) ((has_nvidia)) ;;
    *) return 1 ;;
  esac
}

resolved_primary_vendor() {
  if [[ "$GPU_PRIMARY" != auto ]]; then
    if ! vendor_present "$GPU_PRIMARY"; then
      echo "--gpu-primary $GPU_PRIMARY was requested, but no $GPU_PRIMARY GPU was detected." >&2
      return 1
    fi

    count="$(paths_for_vendor_count "$GPU_PRIMARY")"
    if ((count != 1)); then
      echo "--gpu-primary $GPU_PRIMARY is ambiguous: detected $count ${GPU_PRIMARY} GPUs. Extend the selector to choose by PCI address." >&2
      return 1
    fi

    printf '%s\n' "$GPU_PRIMARY"
    return
  fi

  if ((${#GPU_PATHS[@]} == 1)); then
    vendor_for_path "${GPU_PATHS[0]}"
    return
  fi

  # On multi-GPU systems auto deliberately does not guess which physical GPU
  # owns the user's displays. An explicit --gpu-primary makes the choice stable.
  printf '\n'
}

# Validate an explicit primary policy during every detector action, including
# package planning, so --dry-run fails before anything is installed.
PRIMARY_VENDOR="$(resolved_primary_vendor)" || exit 1

kernel_packages() {
  local k found=0
  for k in linux linux-lts linux-zen linux-hardened; do
    if pacman -Qq "$k" &>/dev/null; then
      printf '%s\n' "$k"
      found=1
    fi
  done

  if ((found == 0)); then
    local pkgbase_file="/usr/lib/modules/$(uname -r)/pkgbase"
    if [[ -r "$pkgbase_file" ]]; then
      cat "$pkgbase_file"
    elif grep -qx 'linux' "$REPO_ROOT/modules/base/packages.txt"; then
      printf 'linux\n'
    else
      return 1
    fi
  fi
}

nvidia_packages() {
  local -a kernels=()
  local k need_dkms=0

  mapfile -t kernels < <(kernel_packages | sort -u)
  ((${#kernels[@]})) || {
    echo "NVIDIA detected, but no supported installed kernel package could be identified." >&2
    return 1
  }

  for k in "${kernels[@]}"; do
    case "$k" in
      linux|linux-lts) ;;
      linux-zen|linux-hardened) need_dkms=1 ;;
      *)
        echo "NVIDIA detected with unsupported/custom kernel pkgbase '$k'. Add its headers mapping manually." >&2
        return 1
        ;;
    esac
  done

  printf 'nvidia-utils\n'

  if ((need_dkms)); then
    printf 'nvidia-open-dkms\n'
    for k in "${kernels[@]}"; do
      printf '%s-headers\n' "$k"
    done
  else
    for k in "${kernels[@]}"; do
      case "$k" in
        linux) printf 'nvidia-open\n' ;;
        linux-lts) printf 'nvidia-open-lts\n' ;;
      esac
    done
  fi
}

describe_gpu() {
  local path="$1" bdf vendor device description=""
  bdf="${path##*/}"
  vendor="$(<"$path/vendor")"
  device="$(<"$path/device")"

  if command -v lspci >/dev/null; then
    description="$(lspci -s "$bdf" -nn 2>/dev/null | sed -E 's/^[^ ]+[[:space:]]+//' || true)"
  fi

  if [[ -n "$description" ]]; then
    printf '%s — %s\n' "$bdf" "$description"
  else
    printf '%s — vendor=%s device=%s\n' "$bdf" "$vendor" "$device"
  fi
}

stable_records() {
  local path vendor idx_amd=0 idx_intel=0 idx_nvidia=0 name

  for path in "${GPU_PATHS[@]}"; do
    vendor="$(vendor_for_path "$path")"
    case "$vendor" in
      amd)
        name="arch-gpu-amd-$idx_amd"
        idx_amd=$((idx_amd + 1))
        ;;
      intel)
        name="arch-gpu-intel-$idx_intel"
        idx_intel=$((idx_intel + 1))
        ;;
      nvidia)
        name="arch-gpu-nvidia-$idx_nvidia"
        idx_nvidia=$((idx_nvidia + 1))
        ;;
    esac
    printf '%s|%s|%s\n' "$vendor" "${path##*/}" "$name"
  done
}

drm_devices_value() {
  [[ -n "$PRIMARY_VENDOR" ]] || return 0

  local -a primary=() rest=()
  local vendor bdf name
  while IFS='|' read -r vendor bdf name; do
    if [[ "$vendor" == "$PRIMARY_VENDOR" ]]; then
      primary+=("/dev/dri/$name")
    else
      rest+=("/dev/dri/$name")
    fi
  done < <(stable_records)

  local IFS=:
  printf '%s' "${primary[*]}"
  if ((${#rest[@]})); then
    ((${#primary[@]})) && printf ':'
    printf '%s' "${rest[*]}"
  fi
  printf '\n'
}

udev_rules() {
  [[ -n "$PRIMARY_VENDOR" ]] || return 0

  local vendor bdf name
  while IFS='|' read -r vendor bdf name; do
    printf 'KERNEL=="card*", KERNELS=="%s", SUBSYSTEM=="drm", SUBSYSTEMS=="pci", SYMLINK+="dri/%s"\n' \
      "$bdf" "$name"
  done < <(stable_records)
}

describe_primary() {
  if [[ -z "$PRIMARY_VENDOR" ]]; then
    printf 'GPU primary policy: auto + multiple GPUs -> no AQ_DRM_DEVICES override (no topology guess).\n'
    printf '  pass --gpu-primary nvidia|amd|intel to force a deterministic Hyprland renderer.\n'
    return
  fi

  if [[ "$GPU_PRIMARY" == auto ]]; then
    printf 'GPU primary policy: auto -> %s (only detected GPU).\n' "$PRIMARY_VENDOR"
  else
    printf 'GPU primary policy: %s -> %s is first in AQ_DRM_DEVICES.\n' "$GPU_PRIMARY" "$PRIMARY_VENDOR"
  fi
  printf '  AQ_DRM_DEVICES: %s\n' "$(drm_devices_value)"
}

case "$ACTION" in
  packages)
    packages=()
    ((has_amd)) && packages+=(mesa)
    ((has_intel)) && packages+=(mesa)

    if ((has_nvidia)); then
      if ! nv_output="$(nvidia_packages)"; then
        exit 1
      fi
      mapfile -t nvpkgs <<< "$nv_output"
      packages+=("${nvpkgs[@]}")

      # PRIME helper is intentionally hybrid-only.
      if ((has_amd || has_intel)); then
        packages+=(nvidia-prime)
      fi
    fi

    printf '%s\n' "${packages[@]}" | awk 'NF && !seen[$0]++'
    ;;

  describe)
    printf 'GPU controllers:\n'
    for path in "${GPU_PATHS[@]}"; do
      printf '  '
      describe_gpu "$path"
    done

    ((has_amd)) && printf 'AMD GPU -> mesa (kernel amdgpu driver is built into Linux)\n'
    ((has_intel)) && printf 'Intel GPU -> mesa (kernel i915/xe driver is built into Linux)\n'
    if ((has_nvidia)); then
      printf 'NVIDIA GPU -> current Arch NVIDIA open-kernel-module stack + nvidia-utils\n'
      printf '  note: nvidia-open supports Turing/GTX 16xx/RTX and newer; older NVIDIA cards need a legacy/manual path\n'
      printf '  kernel packages: '
      kernel_packages | paste -sd' ' -
      printf '\n'
    fi

    if ((has_amd && has_nvidia)); then
      printf 'Hybrid graphics detected: AMD + NVIDIA; drivers for BOTH + nvidia-prime (prime-run) will be installed.\n'
    elif ((has_intel && has_nvidia)); then
      printf 'Hybrid graphics detected: Intel + NVIDIA; drivers for BOTH + nvidia-prime (prime-run) will be installed.\n'
    fi

    describe_primary
    ;;

  drm-devices)
    drm_devices_value
    ;;

  udev-rules)
    udev_rules
    ;;

  primary)
    describe_primary
    ;;

  *)
    echo "Unknown action: $ACTION" >&2
    exit 2
    ;;
esac
