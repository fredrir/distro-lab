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

