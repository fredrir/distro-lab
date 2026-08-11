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