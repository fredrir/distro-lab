output "labs" {
  value = {
    for name, lab in module.registry.labs : name => {
      ipv4             = lab.ipv4
      mac_address      = lab.mac_address
      idle             = lab.idle
      state_share_path = lab.state_share_path
    }
  }
}

output "pool" {
  value = libvirt_pool.images.name
}

output "network" {
  value = libvirt_network.dlab.name
}
