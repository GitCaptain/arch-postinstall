# arch-postinstall

Modular Arch Linux post-install repository. `base` is always selected.

## Recommended installation

First inspect the exact plan:

```bash
./setup-arch.sh \
  --dry-run \
  --module btrfs \
  --module gui \
  --module audio \
  --gpu-primary nvidia \
  --btrfs-compression zstd:-3 \
  --swap-size 16G
```

Then run the same command without `--dry-run`.

## Hardware auto-detection

### CPU microcode (`base`)

`modules/base/detect-packages.sh` reads the CPU vendor:

- AMD -> `amd-ucode`
- Intel -> `intel-ucode`
- anything else -> installer error; no guessed microcode package

`capture-current-base.sh` deliberately excludes both microcode packages so the
captured manifest remains portable between AMD and Intel machines.

### GPU (`gui`)

All PCI display/3D controllers are scanned, so hybrid systems are supported.

- AMD -> `mesa`
- Intel -> `mesa`
- NVIDIA -> `nvidia-utils` plus the appropriate `nvidia-open` kernel package
- hybrid AMD/Intel + NVIDIA -> also `nvidia-prime` for the `prime-run` offload helper; it is not added on NVIDIA-only systems
- unknown vendor -> installer error instead of guessing

For stock `linux` the NVIDIA kernel package is `nvidia-open`; for `linux-lts`
it is `nvidia-open-lts`. Systems using `linux-zen`/`linux-hardened` use
`nvidia-open-dkms` plus matching headers.

Current NVIDIA open kernel modules require Turing or newer GPUs (including
GTX 16xx/RTX generations). Legacy NVIDIA hardware needs a separate/manual path.

Gaming/multilib Vulkan packages are intentionally not installed here.

### Primary GPU for Hyprland

Use `--gpu-primary auto|nvidia|amd|intel`. `auto` selects the only GPU on a
single-GPU machine. On a multi-GPU machine it deliberately does not guess the
physical display topology and leaves `AQ_DRM_DEVICES` unset. Use an explicit
value for deterministic hybrid setups, for example:

```bash
--gpu-primary nvidia
```

With an explicit primary, the GUI module creates stable udev symlinks under
`/dev/dri/arch-gpu-*` and generates `~/.config/hypr/gpu.conf`. The selected
GPU is first in `AQ_DRM_DEVICES`; all other detected GPUs follow as fallbacks so
outputs attached to them can still be used.

## Minimal GUI

`gui` explicitly selects only:

```text
hyprland
ghostty
hyprpolkitagent
xdg-desktop-portal-hyprland
xdg-desktop-portal-gtk
hyprlock
hypridle
wl-clipboard
noto-fonts
```

Hardware-specific GPU packages are added dynamically.

There is no Waybar, app launcher, notification daemon or wallpaper daemon yet.
Hyprland uses a plain background. `SUPER+L` locks the session. Hypridle locks
after 5 minutes, turns the display off after 5.5 minutes and suspends after
30 minutes.

No display manager is installed. Start Hyprland from a local TTY with:

```bash
start-hyprland
```

## Audio module

`audio` is separate from `gui` and installs:

```text
pipewire
pipewire-audio
pipewire-alsa
pipewire-pulse
wireplumber
```

## Compression benchmark

The benchmark is separate from installation and can compare compression levels
and Btrfs worker-pool sizes:

```bash
./scripts/benchmark-btrfs-compression.sh \
  --thread-pools 8 16 32 \
  --runs 5 \
  --write-runs 10 \
  -5 -3 -1 1 3 5
```

## Capture base packages

Run before adding GUI/extra packages on a source machine:

```bash
./scripts/capture-current-base.sh
```

Optionally bundle public SSH authorized keys:

```bash
./scripts/capture-current-base.sh --copy-authorized-keys
```

No private SSH keys are copied.

## Layout

```text
arch-postinstall/
├── setup-arch.sh
├── assets/
├── modules/
│   ├── base/
│   │   ├── packages.txt
│   │   ├── detect-packages.sh
│   │   └── configure.sh
│   ├── btrfs/
│   │   ├── packages.txt
│   │   └── configure.sh
│   ├── gui/
│   │   ├── packages.txt
│   │   ├── detect-packages.sh
│   │   ├── configure.sh
│   │   └── files/
│   │       ├── hyprland.conf
│   │       ├── hypridle.conf
│   │       └── hyprlock.conf
│   └── audio/
│       ├── packages.txt
│       └── configure.sh
└── scripts/
    ├── capture-current-base.sh
    ├── benchmark-btrfs-compression.sh
    └── new-module.sh
```
