locals {
  is_cloud = var.spec.source.type == "cloud"
  is_nix   = var.spec.source.type == "nix"
  is_iso   = var.spec.source.type == "iso"

  image_path = replace(var.spec.source.image_url, "file://", "")

  cloud_config = merge(
    {
      hostname         = var.name
      manage_etc_hosts = true

      ssh_pwauth   = false
      disable_root = true

      users = [
        {
          name        = var.username
          shell       = "/bin/bash"
          groups      = ["wheel"]
          lock_passwd = true

          sudo = [
            "ALL=(ALL) NOPASSWD:ALL"
          ]

          ssh_authorized_keys = var.ssh_authorized_keys
        }
      ]
    },

    var.cloud_config_extra,
  )

  root_disk = {
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
  }

  work_disks = var.spec.work_volume_name == null ? [] : [
    {
      source = {
        volume = {
          pool   = var.pool
          volume = var.spec.work_volume_name
        }
      }

      target = {
        dev = "vdb"
        bus = "virtio"
      }

      driver = {
        type = "qcow2"
      }
    }
  ]

  cloudinit_disks = [
    for v in libvirt_volume.cloudinit : {
      device = "cdrom"

      source = {
        volume = {
          pool   = v.pool
          volume = v.name
        }
      }

      target = {
        dev = "sda"
        bus = "sata"
      }
    }
  ]

  installer_disks = local.is_iso ? [
    {
      device    = "cdrom"
      read_only = true

      source = {
        file = {
          file = local.image_path
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
  ] : []

  boot_devices = [
    for dev in(local.is_iso ? var.spec.source.boot_order : ["hd"]) : {
      dev = dev
    }
  ]

  hostdevs = [
    for bdf in var.spec.gpu_pci : {
      managed = true

      subsys_pci = {
        source = {
          address = {
            domain   = parseint(split(":", bdf)[0], 16)
            bus      = parseint(split(":", bdf)[1], 16)
            slot     = parseint(split(".", split(":", bdf)[2])[0], 16)
            function = parseint(split(".", split(":", bdf)[2])[1], 16)
          }
        }
      }
    }
  ]
}


resource "libvirt_volume" "base" {
  count = local.is_cloud ? 1 : 0

  name = "${var.name}-base.qcow2"
  pool = var.pool

  target = {
    format = {
      type = "qcow2"
    }
  }

  create = {
    content = {
      url = var.spec.source.image_url
    }
  }
}


resource "libvirt_volume" "root" {
  name     = "${var.name}.qcow2"
  pool     = var.pool
  capacity = local.is_nix ? null : var.spec.disk_size_bytes

  target = {
    format = {
      type = "qcow2"
    }
  }

  backing_store = one([
    for v in libvirt_volume.base : {
      path = v.path

      format = {
        type = "qcow2"
      }
    }
  ])

  create = local.is_nix ? {
    content = {
      url = var.spec.source.image_url
    }
  } : null
}


resource "libvirt_cloudinit_disk" "init" {
  count = local.is_cloud ? 1 : 0

  name = "${var.name}-cloudinit"

  user_data = join("", [
    "#cloud-config\n",
    yamlencode(local.cloud_config)
  ])

  meta_data = yamlencode({
    "instance-id"    = var.name
    "local-hostname" = var.name
  })
}


resource "libvirt_volume" "cloudinit" {
  count = local.is_cloud ? 1 : 0

  name = "${var.name}-cloudinit.iso"
  pool = var.pool

  create = {
    content = {
      url = libvirt_cloudinit_disk.init[count.index].path
    }
  }
}


resource "libvirt_domain" "vm" {
  name  = var.name
  type  = "kvm"
  title = var.spec.title

  running   = var.running
  autostart = var.autostart

  memory      = var.spec.memory_mib
  memory_unit = "MiB"

  current_memory      = var.spec.current_memory_mib
  current_memory_unit = "MiB"

  vcpu         = var.spec.vcpu
  vcpu_current = var.spec.vcpu_current

  memory_backing = {
    memory_source = {
      type = "memfd"
    }

    memory_access = {
      mode = "shared"
    }
  }

  features = {
    acpi = true
    apic = {}
  }

  cpu = {
    mode = "host-passthrough"
  }

  cpu_tune = {
    shares = var.spec.cpu_shares
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

    boot_devices = local.boot_devices
  }

  devices = {
    disks = concat(
      [local.root_disk],
      local.work_disks,
      local.cloudinit_disks,
      local.installer_disks,
    )

    interfaces = [
      {
        type = "network"

        model = {
          type = "virtio"
        }

        mac = {
          address = var.spec.mac_address
        }

        source = {
          network = {
            network = var.network
          }
        }
      }
    ]

    filesystems = [
      {
        access_mode = "passthrough"

        driver = {
          type = "virtiofs"
        }

        binary = var.virtiofsd_path == null ? null : {
          path = var.virtiofsd_path
        }

        source = {
          mount = {
            dir = var.spec.state_share_path
          }
        }

        target = {
          dir = var.spec.state_share_tag
        }
      }
    ]

    hostdevs = local.hostdevs

    mem_balloon = {
      model               = "virtio"
      free_page_reporting = "on"
      auto_deflate        = "on"

      stats = {
        period = 10
      }
    }

    channels = [
      {
        source = {
          unix = {}
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

  destroy = {
    shutdown = {
      timeout = 120
    }
  }

  lifecycle {
    ignore_changes = [running]
  }
}
