provider "libvirt" {
  uri = var.libvirt_uri
}


locals {
  cloud_init_file = "${path.module}/../config/cloud-init.yaml"

  cloud_config_extra = yamldecode(fileexists(local.cloud_init_file) ? file(local.cloud_init_file) : "{}")
}


module "ubuntu_dev" {
  source = "../../../vm/modules/libvirt-cloud-vm"

  name = "ubuntu-dev"

  pool    = var.pool
  network = var.network

  memory_mib = var.ubuntu_dev_memory_mib
  vcpus      = var.ubuntu_dev_vcpus

  disk_size_bytes = var.ubuntu_dev_disk_size_bytes

  username = var.username

  ssh_authorized_keys = var.ssh_authorized_keys

  image_url = var.ubuntu_dev_image_url

  cloud_config_extra = local.cloud_config_extra
}
