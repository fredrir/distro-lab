provider "libvirt" {
  uri = var.libvirt_uri
}


module "nixos_dev" {
  source = "../../../vm/modules/libvirt-iso-vm"

  name = "nixos-dev"

  pool    = var.pool
  network = var.network

  memory_mib = var.nixos_dev_memory_mib
  vcpus      = var.nixos_dev_vcpus

  disk_size_bytes = var.nixos_dev_disk_size_bytes

  iso_path = "${var.distro_lab_path}/ISOs/${var.nixos_dev_iso}"

  boot_order = var.nixos_dev_boot_order
}
