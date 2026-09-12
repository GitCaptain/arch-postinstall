#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-packages}"
PCI_ROOT="${ARCH_SETUP_PCI_ROOT:-/sys/bus/pci/devices}"

shopt -s nullglob
GPU_PATHS=()
for path in "$PCI_ROOT"/*; do
  [[ -r "$path/class" && -r "$path/vendor" && -r "$path/device" ]] || continue
  class="$(<"$path/class")"
  [[ "$class" == 0x03* ]] || continue
  GPU_PATHS+=("$path")
done

((${#GPU_PATHS[@]})) || {
  echo "No PCI display/3D controller was detected under $PCI_ROOT. Refusing to guess a GPU driver." >&2
  exit 1
}

has_amd=0
has_intel=0
has_nvidia=0
unknown=()

for path in "${GPU_PATHS[@]}"; do
  vendor="$(<"$path/vendor")"
  case "${vendor,,}" in
    0x1002) has_amd=1 ;;
    0x8086) has_intel=1 ;;
    0x10de) has_nvidia=1 ;;
    *) unknown+=("${path##*/}: vendor=$vendor device=$(<"$path/device")") ;;
  esac
done

if ((${#unknown[@]})); then
  printf 'Unsupported GPU vendor(s):\n' >&2
  printf '  %s\n' "${unknown[@]}" >&2
  printf 'Add an explicit driver rule to modules/gui/detect-packages.sh instead of guessing.\n' >&2
  exit 1
fi

kernel_packages() {
  local k found=0
  for k in linux linux-lts linux-zen linux-hardened; do
    if pacman -Qq "$k" &>/dev/null; then
      printf '%s\n' "$k"
      found=1
    fi
  done

  if ((found == 0)); then
    # Fallback to the running kernel's pkgbase when possible.
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
    ;;

  *)
    echo "Unknown action: $ACTION" >&2
    exit 2
    ;;
esac
