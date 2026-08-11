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

It can be mounted from Arch at:

```text
/storage/distro-lab/EFI
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

It contains both general storage and distro-lab persistent data.

```text
/storage/
├── distro-lab/
├── Documents/
├── SteamLibrary/
└── ...
```

Within the lab:

```text
/storage/distro-lab/
├── images/
├── ISOs/
├── EFI/
├── roots/
├── src/
└── storage/
```

### Disposable vs persistent

Bare-metal roots are disposable:

```text
/dev/vg_distro_lab/nixos-root
```

Persistent distro-specific data lives outside the thin pool:

```text
/storage/distro-lab/storage/nixos/
```

Deleting `nixos-root` therefore does not delete the persistent NixOS data.

## Repository

The Git repository root is:

```text
/storage/distro-lab
```

`src/` contains configuration and infrastructure code:

```text
src/
├── distros/
├── vm/
├── efibootmgr-before-nixos.txt
└── vg_distro_lab-before-nixos.conf
```

Runtime or large binary data lives outside `src/`, including:

```text
images/
ISOs/
roots/
storage/
EFI/
```

## VM

Configuration lives under:

```text
src/distros/<distro>-dev/
src/vm/
```

VM disks live under:

```text
images/ # E.g: images/nixos-dev.qcow2
```

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
/storage/distro-lab/storage/<distro>/
```

This is intentionally independent of disposable VM or bare-metal root filesystems.
