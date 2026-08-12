## VM workflow

VMs are managed with libvirt and OpenTofu.

Every VM is described by an OpenTofu stack under `src/distros/<distro>/tofu/`,
driven through the root `Makefile`, which sources `.env` first:

```bash
make nixos-dev/plan
make nixos-dev/apply
```

The `shared` stack owns the libvirt storage pool and must be applied before any
distro stack:

```bash
make shared/apply
```

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

Lab VMs are disposable, so their SSH host keys change every time a VM is
rebuilt. The `*-dev` block therefore sets:

```text
UserKnownHostsFile /dev/null
StrictHostKeyChecking no
```

Without this, every rebuild triggers `REMOTE HOST IDENTIFICATION HAS CHANGED`
and the connection is refused until the old key is removed by hand. The
tradeoff is that these hosts are not authenticated; the connection reaches them
either from the host itself or through an already-authenticated hop to it.

## Base images

`TF_VAR_gentoo_dev_image_url` points at a dated build under Gentoo's
`autobuilds/` directory. That directory keeps only the most recent handful of
builds, so a pinned URL eventually returns 404 and a fresh create stops working.
Gentoo publishes `latest-di-amd64-cloudinit.txt`, but it is a signed text file
rather than a redirect, so it cannot be used as `image_url` directly.

`gentoo-dev` therefore pins a local image kept in `ISOs/`:

```text
TF_VAR_gentoo_dev_image_url="file://${TF_VAR_distro_lab_path}/ISOs/di-amd64-cloudinit-20260809T143052Z.qcow2"
```

Fetching over HTTPS runs at roughly 11 MB/s, so a 1.9 GiB image costs about
2m45s. Copying from `ISOs/` makes a full destroy and recreate of the whole stack
take about 3 seconds.

`ubuntu-dev` pins a local image for that second reason alone. Ubuntu's release
URLs are stable, so nothing rots there:

```text
TF_VAR_ubuntu_dev_image_url="file://${TF_VAR_distro_lab_path}/ISOs/ubuntu-26.04-server-cloudimg-amd64.img"
```

The file is qcow2 despite the `.img` suffix, which is the format the module's
base volume declares.

## Updating a pinned image

Download the build, verify it against Gentoo's signed digests, then repoint
`.env`:

```bash
build=20260811T083102Z
base=https://distfiles.gentoo.org/releases/amd64/autobuilds/$build

curl -O --output-dir ISOs "$base/di-amd64-cloudinit-$build.qcow2"
curl -s "$base/di-amd64-cloudinit-$build.qcow2.DIGESTS" | grep -A1 "SHA512 HASH"
sha512sum ISOs/di-amd64-cloudinit-$build.qcow2
```

Only change `image_url` as part of a rebuild:

```bash
make gentoo-dev/destroy
make gentoo-dev/apply
```

Applying the change to a running VM replaces `libvirt_volume.base` while
`libvirt_volume.root` is merely updated in place, and root is a qcow2 overlay
backed by that exact file. Swapping the backing image for different content
corrupts the VM silently.

## Cloud-image VMs

`gentoo-dev` and `ubuntu-dev` use the `libvirt-cloud-vm` module. The base image
is fetched from that distro's `TF_VAR_*_image_url`, and cloud-init creates the
user and installs the keys from `TF_VAR_ssh_authorized_keys`. Applying the stack
produces a VM that is reachable over SSH without any manual step.

## Provisioning a cloud VM

Guest configuration lives with the distro, not in `.env`:

```text
src/distros/gentoo-dev/config/cloud-init.yaml
```

The stack reads that file and the module merges it over the cloud-config it
generates, so anything cloud-init accepts works without adding OpenTofu
variables. The generated half owns `hostname`, `users` and the SSH keys, because
those come from the VM name and from `.env`; the file owns everything else.

`.env` is deliberately not the place for this. It holds values that vary per
machine — paths, the libvirt URI, sizes, keys — and it is not tracked. What a
distro installs is part of the distro, so it belongs beside
`nixos-dev/config/configuration.nix`.

The file applies once, on the first boot of a given instance. Editing it does not
re-provision a VM that already exists; the change takes effect on the next
destroy and recreate.

`packages:` is the more obvious cloud-init key to reach for, but cloud-init's
Gentoo handler invokes a bare `emerge`, and the cloud image sets no
`--getbinpkg` default, so a package list compiles from source. `runcmd` is used
instead so the official signed binary host is requested explicitly:

```yaml
runcmd:
  - emerge-webrsync
  - emerge --getbinpkg --quiet app-emulation/qemu-guest-agent
```

The guest agent needs no service enabling. It ships a udev rule that sets
`SYSTEMD_WANTS=qemu-guest-agent.service`, so it starts when the virtio channel
declared by the module appears.

This costs a portage tree sync on every fresh build, roughly 600 MiB, and needs
working outbound networking in the guest. When neither is acceptable, install
the packages once and pin the result as the base image in `ISOs/` instead, which
keeps a rebuild at about three seconds.

Ubuntu has neither problem, so `ubuntu-dev/config/cloud-init.yaml` reaches for
`packages:` directly:

```yaml
package_update: true

packages:
  - qemu-guest-agent
```

## ISO-installed VMs

NixOS publishes no cloud image, so `nixos-dev` uses the `libvirt-iso-vm` module.
OpenTofu creates a blank root volume and a domain with the installer ISO named by
`TF_VAR_nixos_dev_iso` attached as a CD-ROM. The guest itself is not managed by
OpenTofu; it comes from `src/distros/nixos-dev/config/`.

The boot order is `TF_VAR_nixos_dev_boot_order`, by default:

```text
["hd", "cdrom"]
```

A freshly created root volume is empty and has no EFI boot entry, so the firmware
falls through to the installer. Once NixOS is installed, the same order boots the
disk and the attached ISO is simply ignored.

Install into a newly applied VM over the serial console:

```bash
virsh -c qemu:///system console nixos-dev
```

Partition, mount, then copy the tracked configuration into place:

```bash
nixos-generate-config --root /mnt
cp /path/to/configuration.nix /mnt/etc/nixos/configuration.nix
nixos-install
```

`hardware-configuration.nix` is regenerated by the installer, because it records
the disk UUIDs of that particular root volume. Afterwards the VM is maintained
with `nixos-rebuild`, not by re-applying OpenTofu.

## Rebuilding a VM from scratch

`tofu destroy` removes the domain and its root volume, discarding the installed
system:

```bash
make nixos-dev/destroy
make nixos-dev/apply
```

The libvirt storage pool and anything under `storage/<distro>/` survive this.

## Adopting a VM created outside OpenTofu

A domain built by hand cannot simply be applied over: the pool already holds a
volume of that name, and the domain already exists. Either import it:

```bash
tofu import module.nixos_dev.libvirt_domain.vm <uuid>
```

which requires the configuration to match the existing XML exactly, or remove
the old VM first:

```bash
virsh -c qemu:///system destroy nixos-dev
virsh -c qemu:///system undefine --nvram nixos-dev
virsh -c qemu:///system vol-delete --pool images nixos-dev.qcow2
```

Take a copy of the disk image before doing this if the installed system matters.
