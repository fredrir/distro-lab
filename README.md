# Distro Lab

Bare-metal and virtual Linux distro lab hosted from Arch Linux.

The lab keeps distro experiments separate from the main Arch installation while providing shared storage, reusable VM infrastructure, and persistent per-distro data.

## Layout
distro-lab/
├── src/        # tracked configuration and infrastructure
├── images/     # VM disk images
├── ISOs/       # installation media
├── roots/      # mountpoints for bare-metal roots
├── EFI/        # LABEFI mountpoint
└── storage/    # persistent per-distro data

## Documentation
- [`docs/architecture.md`](./docs/architecture.md) — host, disks, LVM, storage and state.
    
- [`docs/workflows.md`](./docs/workflows.md) — common VM and bare-metal workflows.

## `src/`

### `distros/`

Distros are organized as:

```text
<distro-name>-<purpose>/
```

Examples:

```text
nixos-main   # bare-metal NixOS experiment
nixos-dev    # NixOS development VM
gentoo-dev   # Gentoo development VM
```

Purposes:

- `dev` — development environment, normally a VM.
    
- `main` — bare-metal distro testing.
    

Each distro may contain:

```text
config/      # distro configuration
tofu/        # OpenTofu infrastructure
```

### `vm/`

Shared libvirt/OpenTofu infrastructure: