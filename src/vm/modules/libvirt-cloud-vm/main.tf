locals {
  # Derive a stable MAC from the VM name, instead; 52:54:00 is the QEMU OUI.
  mac_digest = substr(md5(var.name), 0, 6)

  mac_address = join(":", [
    "52", "54", "00",
    substr(local.mac_digest, 0, 2),
    substr(local.mac_digest, 2, 2),
    substr(local.mac_digest, 4, 2),
  ])

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
}


# ─────────────────────────────────────────────────────────────
# Base distro image
# ─────────────────────────────────────────────────────────────

resource "libvirt_volume" "base" {
  name = "${var.name}-base.qcow2"
  pool = var.pool

  target = {
    format = {
      type = "qcow2"
    }
  }

  create = {
    content = {
      url = var.image_url
    }
  }
}


# ─────────────────────────────────────────────────────────────
# Writable VM disk
# ─────────────────────────────────────────────────────────────

resource "libvirt_volume" "root" {
  name     = "${var.name}.qcow2"
  pool     = var.pool
  capacity = var.disk_size_bytes

  target = {
    format = {
      type = "qcow2"
    }
  }

  backing_store = {
    path = libvirt_volume.base.path

    format = {
      type = "qcow2"
    }
  }
}


# ─────────────────────────────────────────────────────────────
# Cloud-init
# ─────────────────────────────────────────────────────────────

resource "libvirt_cloudinit_disk" "init" {
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
  name = "${var.name}-cloudinit.iso"
  pool = var.pool

  create = {
    content = {
      url = libvirt_cloudinit_disk.init.path
    }
  }
}


# ─────────────────────────────────────────────────────────────
# VM
# ─────────────────────────────────────────────────────────────

resource "libvirt_domain" "vm" {
  name        = var.name
  type        = "kvm"
  memory      = var.memory_mib
  memory_unit = "MiB"
  vcpu        = var.vcpus

  # UEFI on x86_64 refuses to start without ACPI, and APIC is expected
  # by any modern guest kernel.
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

    # Distro cloud images are GPT with an EFI System Partition and no legacy
    # MBR boot code, so they are unbootable under SeaBIOS (libvirt's default).
    firmware = "efi"

    # Pick the plain OVMF build: cloud image kernels/bootloaders are unsigned.
    # Keep this order: the provider reads the features back in libvirt's own
    # ordering, and any other order fails apply with "inconsistent result".
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
      {
        dev = "hd"
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
        device = "cdrom"

        source = {
          volume = {
            pool   = libvirt_volume.cloudinit.pool
            volume = libvirt_volume.cloudinit.name
          }
        }

        target = {
          dev = "sda"
          bus = "sata"
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

    # Gives `virsh console <name>` for firmware and cloud-init output.
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
