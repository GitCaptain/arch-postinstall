# arch-setup

Small modular Arch Linux post-install repository.

## Rule

`setup-arch.sh` only consumes files already committed to this repository.
It does not capture packages, generate manifests, or run benchmarks.

`base` is always selected.

```bash
./setup-arch.sh --dry-run --module btrfs --module gui
./setup-arch.sh --module btrfs --module gui
```

Btrfs options are inputs to the Btrfs module:

```bash
./setup-arch.sh \
  --module btrfs \
  --btrfs-compression zstd:3 \
  --swap-size 16G
```

## Capture the current base machine

Do this now, before installing the GUI/extra modules:

```bash
./scripts/capture-current-base.sh
```

Optionally bundle the user's public SSH authorized keys:

```bash
./scripts/capture-current-base.sh --copy-authorized-keys
```

No private SSH key is copied.

## Compression benchmark

This is intentionally separate from installation:

```bash
./scripts/benchmark-btrfs-compression.sh /usr/bin 1 3 5 8
```

Choose a result, then pass it to `setup-arch.sh` via `--btrfs-compression`.

## Add another module

```bash
./scripts/new-module.sh dev
```

Then edit:

```text
modules/dev/packages.txt
modules/dev/configure.sh
```

Use it with:

```bash
./setup-arch.sh --module dev
```

## Layout

```text
arch-setup/
├── setup-arch.sh
├── assets/
├── modules/
│   ├── base/
│   │   ├── packages.txt
│   │   └── configure.sh
│   ├── btrfs/
│   │   ├── packages.txt
│   │   └── configure.sh
│   └── gui/
│       ├── packages.txt
│       ├── configure.sh
│       └── files/hyprland.conf
└── scripts/
    ├── capture-current-base.sh
    ├── benchmark-btrfs-compression.sh
    └── new-module.sh
```

Each module has two interfaces:

- `configure.sh plan` — description only; must not change the system.
- `configure.sh apply` — performs configuration after package installation.
