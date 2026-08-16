provider "libvirt" {
  uri = var.libvirt_uri
}


locals {
  lab = "dlab-cuda"

  cloud_init_file = "${path.module}/../config/cloud-init.yaml"

  cloud_config_extra = yamldecode(fileexists(local.cloud_init_file) ? file(local.cloud_init_file) : "{}")
}


module "registry" {
  source = "../../../vm/modules/lab-registry"

  labs            = jsondecode(file("${path.module}/../../labs.json"))
  distro_lab_path = var.distro_lab_path
  subnet_prefix   = var.subnet_prefix
}


module "vm" {
  source = "../../../vm/modules/libvirt-lab-vm"

  name = local.lab
  spec = module.registry.labs[local.lab]

  pool    = var.pool
  network = var.network

  username            = var.username
  ssh_authorized_keys = var.ssh_authorized_keys

  cloud_config_extra = local.cloud_config_extra
}
