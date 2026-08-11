# Workflows

## VM workflow

VMs are managed with libvirt and OpenTofu.




List VMs:

```bash
virsh -c qemu:///system list --all
```

Inspect a VM:

```bash
virsh -c qemu:///system dumpxml nixos-dev
```

SSH into a development VM:

```bash
ssh nixos-dev
```

The SSH config uses:

```text
src/vm/libvirt-ssh-proxy
```

to resolve the current DHCP address through libvirt.

## Bare-metal workflow

Bare-metal distro roots are thin LVs inside:

```text
vg_distro_lab/labpool
```

### Create a root

Example:

```bash
sudo lvcreate \
  --type thin \
  --name nixos-root \
  --virtualsize 700G \
  --thinpool labpool \
  vg_distro_lab
```

### Inspect LVM

```bash
sudo pvs
sudo vgs
sudo lvs -a
```

Pool health:

```bash
sudo lvs \
  -o lv_name,lv_size,data_percent,metadata_percent,seg_monitor \
  vg_distro_lab
```

### Mount a root from Arch

Example:

```bash
sudo mount \
  /dev/vg_distro_lab/nixos-root \
  /storage/distro-lab/roots/nixos
```

Unmount:

```bash
sudo umount /storage/distro-lab/roots/nixos
```

### Mount LABEFI

```bash
sudo mount \
  /dev/disk/by-label/LABEFI \
  /storage/distro-lab/EFI
```

Unmount:

```bash
sudo umount /storage/distro-lab/EFI
```

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
