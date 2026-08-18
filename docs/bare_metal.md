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
sudo mkdir -p /storage/dlab-mounts/roots/nixos
sudo mount \
  /dev/vg_distro_lab/nixos-root \
  /storage/dlab-mounts/roots/nixos
```

Unmount:

```bash
sudo umount /storage/dlab-mounts/roots/nixos
```

### Mount LABEFI

```bash
sudo mkdir -p /storage/dlab-mounts/EFI
sudo mount \
  /dev/disk/by-label/LABEFI \
  /storage/dlab-mounts/EFI
```

Unmount:

```bash
sudo umount /storage/dlab-mounts/EFI
```

