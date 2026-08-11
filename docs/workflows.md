# Workflows

## VM workflow

[vm.md](./vm.md)

## Bare-metal workflow

[bare_metal.md](./bare_metal.md)

## Persistent distro data

Create persistent storage separately from the distro root:

```bash
mkdir -p /storage/distro-lab/storage/nixos
```

The intended lifecycle is:

```text
create distro root
        ↓
experiment
        ↓
keep useful data in storage/<distro>
        ↓
delete distro root
        ↓
persistent data remains
```

## Remove an experiment

Ensure the root is not mounted or running.

Then:

```bash
sudo lvremove vg_distro_lab/nixos-root
```

Do not remove:

```text
/storage/distro-lab/storage/nixos/
```

unless the persistent data should also be discarded.

## LVM metadata snapshot

Record the current VG layout:

```bash
sudo vgcfgbackup \
  -f src/vg_distro_lab.conf \
  vg_distro_lab
```

This records the LVM layout, not the actual filesystem data.

## EFI state snapshot

```bash
sudo efibootmgr -v > src/efibootmgr.txt
```
