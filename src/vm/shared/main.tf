provider "libvirt" {
  uri = var.libvirt_uri
}


module "registry" {
  source = "../modules/lab-registry"

  labs         = jsondecode(file("${path.module}/../../labs/labs.json"))
  storage_path = var.storage_path
}


resource "libvirt_pool" "images" {
  name = var.pool
  type = "dir"

  target = {
    path = "${var.storage_path}/images"
  }

  create = {
    build     = false
    start     = true
    autostart = true
  }

  destroy = {
    delete = false
  }
}


resource "libvirt_network" "dlab" {
  name      = var.network
  autostart = true

  bridge = {
    name = "virbr-dlab"
    stp  = "on"
  }

  # The DNS domain is a guest-visible fact, so it comes from the registry's
  # network file alongside the subnet, not from the name of the libvirt object.
  domain = {
    name       = module.registry.network.domain
    local_only = "yes"
  }

  forward = {
    mode = "nat"
  }

  dns = {
    enable = "yes"

    host = [
      for lab in module.registry.labs : {
        ip = lab.ipv4

        hostnames = [
          {
            hostname = lab.name
          }
        ]
      }
    ]
  }

  ips = [
    {
      address = module.registry.network.gateway_ipv4
      netmask = module.registry.network.netmask

      # NixOS labs configure their address statically and never ask, but the
      # reservations stay: they are what makes the address theirs to bake in,
      # and the cloud and iso labs still lease.
      dhcp = {
        hosts = [
          for lab in module.registry.labs : {
            name = lab.name
            mac  = lab.mac_address
            ip   = lab.ipv4
          }
        ]
      }
    }
  ]
}


resource "libvirt_volume" "work" {
  for_each = {
    for name, lab in module.registry.labs : name => lab
    if lab.work_volume_name != null
  }

  name     = each.value.work_volume_name
  pool     = libvirt_pool.images.name
  capacity = each.value.work_disk_bytes

  target = {
    format = {
      type = "qcow2"
    }
  }
}
