output "name" {
  value = libvirt_domain.vm.name
}

output "id" {
  value = libvirt_domain.vm.id
}

output "disk_path" {
  value = libvirt_volume.root.path
}

output "iso_path" {
  value = var.iso_path
}
