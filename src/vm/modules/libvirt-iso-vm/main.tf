locals {
  mac_digest = substr(md5(var.name), 0, 6)

  mac_address = join(":", [
    "52", "54", "00",
    substr(local.mac_digest, 0, 2),
    substr(local.mac_digest, 2, 2),
    substr(local.mac_digest, 4, 2),
  ])
}


resource "libvirt_volume" "root" {
  name     = "${var.name}.qcow2"
  pool     = var.pool
  capacity = var.disk_size_bytes

  target = {
    format = {
      type = "qcow2"
    }
  }
}


resource "libvirt_domain" "vm" {
  name        = var.name
  type        = "kvm"
  memory      = var.memory_mib
  memory_unit = "MiB"
  vcpu        = var.vcpus

  features = {
    acpi = true
    apic = {}
  }

  cpu = {
    mode = "host-passthrough"
  }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"

    firmware = "efi"

    firmware_info = {
      features = [
        {
          name    = "enrolled-keys"
          enabled = "no"
        },
        {
          name    = "secure-boot"
          enabled = "no"
        }
      ]
    }

    boot_devices = [
      for dev in var.boot_order : {
        dev = dev
      }
    ]
  }

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_volume.root.pool
            volume = libvirt_volume.root.name
          }
        }

        target = {
          dev = "vda"
          bus = "virtio"
        }

        driver = {
          type = "qcow2"
        }
      },

      {
        device    = "cdrom"
        read_only = true

        source = {
          file = {
            file = var.iso_path
          }
        }

        target = {
          dev = "sda"
          bus = "sata"
        }

        driver = {
          type = "raw"
        }
      }
    ]

    interfaces = [
      {
        type = "network"

        model = {
          type = "virtio"
        }

        mac = {
          address = local.mac_address
        }

        source = {
          network = {
            network = var.network
          }
        }
      }
    ]

    channels = [
      {
        source = {
          unix = {
            mode = "bind"
          }
        }

        target = {
          virt_io = {
            name = "org.qemu.guest_agent.0"
          }
        }
      }
    ]

    graphics = [
      {
        vnc = {
          auto_port = true
          listen    = "127.0.0.1"
        }
      }
    ]

    serials = [
      {
        target = {
          type = "isa-serial"
          port = 0
        }
      }
    ]

    consoles = [
      {
        target = {
          type = "serial"
          port = 0
        }
      }
    ]
  }

  running = true
}
