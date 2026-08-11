provider "libvirt" {
  uri = var.libvirt_uri
}


module "gentoo_dev" {
  source = "../../../vm/modules/libvirt-cloud-vm"

  name = "gentoo-dev"

  pool    = var.pool
  network = var.network

  memory_mib = var.gentoo_dev_memory_mib
  vcpus      = var.gentoo_dev_vcpus

  disk_size_bytes = var.gentoo_dev_disk_size_bytes

  username = var.username

  ssh_authorized_keys = var.ssh_authorized_keys

  image_url = var.gentoo_dev_image_url
}
