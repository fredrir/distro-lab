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

```text
shared/                     the libvirt storage pool every VM draws from
modules/libvirt-cloud-vm/   VM built from an upstream cloud image plus cloud-init
modules/libvirt-iso-vm/     VM built from install media, guest configured by the distro
ssh/                        ssh client config and the libvirt DHCP proxy
```

Distros whose upstream publishes a cloud image use `libvirt-cloud-vm`, and the
guest is configured by cloud-init. NixOS publishes no such image, so `nixos-dev`
uses `libvirt-iso-vm`: OpenTofu owns the virtual hardware, and the guest comes
from `src/distros/nixos-dev/config/`.

## Configuration

All environment-specific values live in `.env` at the repository root. Copy the
template and edit it:

```bash
cp .env.example .env
```

Every entry is a `TF_VAR_*` variable, so OpenTofu consumes it directly. Each
stack declares the variables it needs in its own `variables.tf`, and none of
them have defaults — a missing entry in `.env` fails the run rather than
silently falling back.

`.env` is not tracked. `.env.example` is.

## Usage

The `Makefile` sources `.env` and runs OpenTofu against a chosen stack:

```bash
make <stack>/<action>
```

Stacks are `shared`, `gentoo-dev` and `nixos-dev`. Actions are `init`,
`validate`, `plan`, `apply`, `destroy`, `refresh`, `output` and `show`.

```bash
make shared/apply
make nixos-dev/plan
make nixos-dev/apply TOFU_ARGS=-auto-approve
```

`make env` prints the variables that would be handed to OpenTofu, and `make fmt`
formats everything under `src/`.

`FAST=1` adds `-refresh=false -lock=false` to `plan`, `apply` and `destroy`,
skipping the reconciliation pass against libvirt. Use it when nothing has
changed the VMs behind OpenTofu's back:

```bash
make nixos-dev/plan FAST=1
```

`TF_PLUGIN_CACHE_DIR` in `.env` makes every stack share one copy of the libvirt
provider instead of downloading 26 MB per stack.