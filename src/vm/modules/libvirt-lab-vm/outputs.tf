output "name" {
  value = libvirt_domain.vm.name
}

output "id" {
  value = libvirt_domain.vm.id
}

output "uuid" {
  value = libvirt_domain.vm.uuid
}

output "disk_path" {
  value = libvirt_volume.root.path
}

output "mac_address" {
  value = var.spec.mac_address
}
