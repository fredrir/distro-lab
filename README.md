# Distro Lab

Bare-metal and virtual Linux distro lab hosted from Arch Linux.

The lab keeps distro experiments separate from the main Arch installation while providing shared storage, reusable VM infrastructure, and persistent per-lab data.

## Layout
distro-lab/
├── flake.nix   # NixOS labs, built from the registry
├── src/        # tracked configuration and infrastructure
├── images/     # VM disk images
├── ISOs/       # installation media
├── roots/      # mountpoints for bare-metal roots
├── EFI/        # LABEFI mountpoint
└── storage/    # persistent per-lab data

## Documentation
- [`docs/architecture.md`](./docs/architecture.md) — host, disks, LVM, storage and state.

- [`docs/labs.md`](./docs/labs.md) — the registry, the flake, the on-demand and idle lifecycle, secrets.

- [`docs/workflows.md`](./docs/workflows.md) — common lab and bare-metal workflows.

## `src/`

### `labs/`

Every VM lives in the `dlab` namespace and is one entry in `src/labs/labs.json`:

```text
dlab-ubuntu      Ubuntu cloud sandbox
dlab-gentoo      Gentoo cloud sandbox
dlab-nixos       NixOS sandbox
dlab-portfolio   fredrir/portfolio
dlab-archtex     fredrir/ArchTeX
dlab-nsql        fredrir/nsql
dlab-cuda        CUDA C/C++ on a passed-through GPU
```

`kind` distinguishes a `distro` sandbox from a `project` workspace. Bare-metal
distros such as `nixos-main` are not VMs, are not reachable over SSH, and are
not part of this namespace.

Each lab contains:

```text
config/      cloud-init, for cloud labs only
tofu/        a five-line stack that looks the lab up in the registry
```

NixOS labs add an import list under `src/labs/nixos/hosts/` and draw from the
shared modules in `src/labs/nixos/modules/`.

### `vm/`

Shared libvirt/OpenTofu infrastructure:

```text
shared/                    storage pool, the dlab network, persistent work volumes
modules/lab-registry/      registry to validated map; derives MACs and image URLs
modules/libvirt-lab-vm/    one VM module: cloud image, nix image or install media
bin/                       the SSH proxy that starts labs, and the idle stopper
systemd/                   host units for the idle stopper
ssh/                       ssh client config
```

The module owns hardware only. What a guest installs lives in the flake for a
NixOS lab, or in that lab's `config/cloud-init.yaml` for a cloud lab.

## Configuration

All machine-specific values live in `.env` at the repository root. Copy the
template and edit it:

```bash
cp .env.example .env
```

It holds seven `TF_VAR_*` entries — libvirt URI, lab path, pool, network,
subnet, username and SSH keys — and does not grow when you add a lab. Per-lab
sizing, images, repositories and secrets live in the registry instead. Nothing
has a default, so a missing entry fails the run rather than silently falling
back.

`.env` is not tracked. `.env.example` is.

## Usage

The `justfile` loads `.env` and drives OpenTofu, libvirt and the flake. `just`
on its own lists every recipe, grouped:

```bash
just
```

Check the host has everything the lab depends on before anything else:

```bash
just doctor
```

### Stacks

Stacks are `shared` plus whatever exists under `src/labs/`, discovered from the
filesystem rather than hardcoded. The stack is an argument, not part of the
recipe name:

```bash
just apply shared
just plan dlab-nsql
just rebuild dlab-nsql
```

`init`, `validate`, `plan`, `apply`, `refresh`, `output` and `show` pass straight
through to OpenTofu. `destroy` and `rebuild` prompt once, quiesce the lab so its
work disk is flushed, then run unattended. Anything else is still reachable by
appending arguments:

```bash
just plan dlab-nsql -target=module.vm.libvirt_domain.vm
```

`plan-fast` and `apply-fast` add `-refresh=false -lock=false`, skipping the
reconciliation pass against libvirt.

### Labs

```bash
just vms                 # name, state, address, vCPU, memory
just idle                # what the idle stopper currently sees
just up dlab-nsql        # boot and wait for SSH
just down dlab-nsql      # stop, using the registry's idle action
just hold dlab-nsql 3h   # block the idle stopper
just ssh dlab-nsql
just console dlab-nsql
```

Labs are defined powered off. Connecting to one starts it, and it stops itself
once idle — see [`docs/labs.md`](./docs/labs.md).

For NixOS labs:

```bash
just image dlab-nsql     # build the disk image from the flake
just deploy dlab-nsql    # day-2 rebuild in place, no tofu
just lab-keys dlab-nsql  # age identity and SSH host key
```

`just status` puts what OpenTofu believes next to what libvirt actually has,
which is how a VM created or deleted outside OpenTofu shows up.

`TF_PLUGIN_CACHE_DIR` in `.env` makes every stack share one copy of the libvirt
provider instead of downloading 26 MB per stack. `just init` creates it.
