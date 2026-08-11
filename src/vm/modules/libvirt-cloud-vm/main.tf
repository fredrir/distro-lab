locals {
  cloud_config = {
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
  }
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

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"

    boot_devices = [
      "hd"
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

        source = {
          network = {
            network = var.network
          }
        }

        wait_for_ip = {
          timeout = 300
          source  = "lease"
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
  }

  running = true
}
