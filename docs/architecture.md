# Architecture

## Host

The lab is managed from the primary Arch Linux installation.

Hardware:

```text
CPU     AMD Ryzen 7 9800X3D
GPU     NVIDIA GeForce RTX 5070 Ti 16 GB
iGPU    AMD Radeon Graphics
RAM     32 GB DDR5-6000
Board   ASUS TUF B850-PLUS WIFI
```

Primary disk:

```text
2 TB Kingston NVMe
├── Windows
├── Arch /
├── Arch /home
└── ARCHEFI
```

The NVMe contains the main operating systems and is kept separate from distro-lab storage.

## Lab disk

The secondary 2 TB WD HDD is divided into:

```text
/dev/sda
├── sda1   4 GiB      LABEFI
├── sda2   750 GiB    DISTRO-LAB
└── sda3   ~1.1 TiB   storage
```

### LABEFI

Dedicated EFI System Partition for experimental bare-metal operating systems.

```text
sda1
FAT32
LABEL=LABEFI
```

It can be mounted from Arch at a directory made for the purpose. The lab no longer
reserves one, so create it when you need it:

```text
/storage/dlab-mounts/EFI
```

ARCHEFI on the NVMe remains separate.

## LVM distro pool

`DISTRO-LAB` is an LVM physical volume:

```text
sda2
└── vg_distro_lab
    └── labpool
```

`labpool` is a thin-provisioned pool.

Current layout:

```text
vg_distro_lab
├── labpool       ~700 GiB physical thin pool
└── nixos-root    700 GiB virtual ThinLV
```

Thin provisioning lets multiple distro roots share the same physical capacity dynamically.

For example:

```text
nixos-root     700G virtual, 80G used
gentoo-root    700G virtual, 300G used
```

Only actual written blocks consume pool space.

The VG keeps additional free capacity outside `labpool` for automatic pool extension.

## Persistent storage

`sda3` is a normal ext4 filesystem:

```text
LABEL=storage
mountpoint=/storage
```

It holds general storage. The artifact tree used to live here as `/storage/distro-lab/`;
it now sits on the NVMe inside the checkout, and nothing under `/storage` is required for
a lab to start. What remains are mountpoints for the bare-metal work below, made on demand
rather than kept:

```text
/storage/
├── Documents/
├── SteamLibrary/
├── dlab-mounts/   # bare-metal roots and LABEFI, created when mounting
└── ...
```

### Disposable vs persistent

Bare-metal roots are disposable:

```text
/dev/vg_distro_lab/nixos-root
```

Persistent distro-specific data lives outside the thin pool:

```text
/home/fredrir/projects/distro-lab/storage/nixos/
```

Deleting `nixos-root` therefore does not delete the persistent NixOS data.

## Repository

`TF_VAR_storage_path` in `.env` names the artifact tree, and everything that writes an
image or a state share resolves it from there. It points into the checkout, so code and
artifacts sit on one filesystem:

```text
TF_VAR_storage_path="/home/fredrir/projects/distro-lab"
```

The indirection is still worth keeping even though the two trees now coincide: it is what
let the artifacts move off the spinning disk without reinstalling anything. A path that
appears in a domain's XML, in the pool, and inside every overlay's qcow2 header is not one
you want to have hardcoded.

`src/` in the checkout contains configuration and infrastructure code:

```text
src/
├── distros/
├── vm/
├── efibootmgr-before-nixos.txt
└── vg_distro_lab-before-nixos.conf
```

Runtime and large binary data live in the artifact tree, which is gitignored rather than
tracked:

```text
images/
ISOs/
storage/
```

OpenTofu state is per-checkout, in `src/labs/<lab>/tofu/`, so exactly one checkout may
drive a given set of labs.

## Labs

Configuration lives under:

```text
src/labs/<lab>/       registry-driven tofu stack, plus cloud-init for cloud labs
src/labs/nixos/       shared modules and per-host import lists
src/vm/               the VM module, the registry module, lifecycle scripts
flake.nix             NixOS labs, at the repository root
```

Disks live under:

```text
<storage_path>/images/dlab-nsql.qcow2               root, disposable, a thin overlay on the base
<storage_path>/images/dlab-nsql-base-<hash>.qcow2  the built image, compressed and read-only
<storage_path>/images/dlab-nsql-base.store-path    which build that base came from
<storage_path>/images/dlab-nsql-work.qcow2         ~, owned by the shared stack, survives a rebuild
```

Per-lab host state lives under:

```text
<storage_path>/storage/<lab>/state/   age identity, SSH host key, agent credentials, idle markers
```

That directory is shared into the guest over virtiofs at `/var/lib/dlab-state`
and is the only thing host and guest write to in common.

## State

The repository contains several kinds of state.

### Infrastructure snapshots

Examples:

```text
efibootmgr-before-nixos.txt
vg_distro_lab-before-nixos.conf
```

These record firmware/LVM state at useful checkpoints.

They document infrastructure but are not backups of filesystem contents.

### OpenTofu state

OpenTofu-managed VM infrastructure may create:

```text
terraform.tfstate
terraform.tfstate.backup
```

These describe deployed infrastructure and should be treated as state rather than configuration source.

### Persistent distro state

Long-lived distro data belongs under:

```text
/home/fredrir/projects/distro-lab/storage/<distro>/
```

This is intentionally independent of disposable VM or bare-metal root filesystems.
