# Workflows

## Labs

[labs.md](./labs.md) — the registry, the flake, the on-demand and idle lifecycle, secrets.

## Bare metal

[bare_metal.md](./bare_metal.md)

## Persistent distro data

Project labs keep work on a dedicated qcow2 mounted at `~/work`, owned by the shared stack so a lab
rebuild cannot take it. Distro sandboxes have no work disk; anything worth keeping should be copied
out before a rebuild.

```text
create a lab
      ↓
experiment
      ↓
keep useful data in ~/work, or copy it out
      ↓
just rebuild, or just destroy
      ↓
work disk and storage/<lab>/ remain
```

## LVM metadata snapshot

```bash
sudo vgcfgbackup -f src/vg_distro_lab.conf vg_distro_lab
```

Records the LVM layout, not filesystem contents.

## EFI state snapshot

```bash
sudo efibootmgr -v > src/efibootmgr.txt
```
