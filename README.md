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
ubuntu-dev   # Ubuntu development VM
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

Either way the modules own hardware only. What a guest installs and how it is
configured lives in that distro's `config/`, tracked in git —
`configuration.nix` for NixOS, `cloud-init.yaml` for a cloud image.

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

The `justfile` loads `.env` and drives both OpenTofu and libvirt. `just` on its
own lists every recipe, grouped:

```bash
just
```

Check the host has everything the lab depends on before anything else:

```bash
just doctor
```

### Stacks

Stacks are `shared`, `gentoo-dev`, `nixos-dev` and `ubuntu-dev`. The stack is an
argument, not part of the recipe name:

```bash
just apply shared
just plan nixos-dev
just rebuild nixos-dev
```

`init`, `validate`, `plan`, `apply`, `refresh`, `output` and `show` pass straight
through to OpenTofu. `destroy` and `rebuild` prompt once and then run
unattended, so nothing needs `-auto-approve`. Anything else is still reachable
by appending arguments:

```bash
just plan nixos-dev -target=module.nixos_dev.libvirt_domain.vm
```

`plan-fast` and `apply-fast` add `-refresh=false -lock=false`, skipping the
reconciliation pass against libvirt. Use them when nothing has changed the VMs
behind OpenTofu's back:

```bash
just plan-fast nixos-dev
```

### VMs

```bash
just vms                # name, state, address, vCPU, memory
just ip nixos-dev
just ssh nixos-dev
just console nixos-dev
just start nixos-dev
just pool
just df
```

`just status` puts what OpenTofu believes next to what libvirt actually has,
which is how a VM created or deleted outside OpenTofu shows up.

`TF_PLUGIN_CACHE_DIR` in `.env` makes every stack share one copy of the libvirt
provider instead of downloading 26 MB per stack. `just init` creates it.