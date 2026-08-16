output "name" {
  value = module.vm.name
}

output "ipv4" {
  value = module.registry.labs[local.lab].ipv4
}

output "mac_address" {
  value = module.vm.mac_address
}

output "disk_path" {
  value = module.vm.disk_path
}
