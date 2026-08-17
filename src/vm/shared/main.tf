provider "libvirt" {
  uri = var.libvirt_uri
}


module "registry" {
  source = "../modules/lab-registry"

  labs            = jsondecode(file("${path.module}/../../labs/labs.json"))
  storage_path = var.storage_path
  subnet_prefix   = var.subnet_prefix
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

  domain = {
    name       = var.network
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
      address = "${var.subnet_prefix}.1"
      netmask = "255.255.255.0"

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
