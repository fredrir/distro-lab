provider "libvirt" {
  uri = "qemu:///system"
}


locals {
  authorized_keys_file = "${path.module}/../../../ssh/authorized_keys"

  ssh_keys = [
    for line in split("\n", file(local.authorized_keys_file)) :
    trimspace(line)
    if startswith(trimspace(line), "ssh-")
  ]
}


module "gentoo_dev" {
  source = "../../modules/libvirt-cloud-vm"

  name = "gentoo-dev"

  pool    = "vm-images"
  network = "default"

  memory_mib = 6144
  vcpus      = 4

  disk_size_bytes = 53687091200 # 50 GiB

  username = "fredrir"

  ssh_authorized_keys = local.ssh_keys

  image_url = "https://distfiles.gentoo.org/releases/amd64/autobuilds/current-di-amd64-cloudinit/di-amd64-cloudinit-20260726T160854Z.qcow2"
}
