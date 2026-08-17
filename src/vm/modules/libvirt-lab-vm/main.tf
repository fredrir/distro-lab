locals {
  is_cloud = var.spec.source.type == "cloud"
  is_nix   = var.spec.source.type == "nix"
  is_iso   = var.spec.source.type == "iso"

  # libvirt spawns virtiofsd itself and offers no XML for its migration flags,
  # so <binary path> is the only seam. The wrapper lives beside this module
  # rather than in the environment: a lab that cannot restore its own managed
  # save is broken in a way no .env should be able to cause by omission.
  virtiofsd_path = coalesce(
    var.virtiofsd_path,
    abspath("${path.module}/../../bin/dlab-virtiofsd"),
  )

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

    # Without this the guest's weekly fstrim is thrown away at the virtio-blk
    # layer: the trim reaches the driver, the driver has no discard to issue,
    # and the qcow2 keeps every cluster the guest has stopped using. A lab that
    # runs nix gc every week and never gives a byte back is the whole reason a
    # root only ever grew. Unmapping a cluster of an overlay writes a zero
    # marker rather than a hole, so the base underneath still cannot show
    # through.
    driver = {
      type    = "qcow2"
      discard = "unmap"
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

      # The home disk survives a rebuild, so it is the one that accumulates
      # across the longest span — build trees, node_modules, cargo targets.
      driver = {
        type    = "qcow2"
        discard = "unmap"
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


# The provider does not mark backing_store as forcing replacement: it plans a
# changed base as an in-place update and then refuses it at apply time with
# "Storage volumes cannot be updated". A new base would wedge the stack. Carry
# the base path in something whose replacement can be triggered, and hang the
# root off it, so `just image` followed by `just apply` recreates the overlay.
#
# Only nix labs need it. A cloud lab's base keeps one name however often it is
# re-uploaded, so its backing path never changes.
resource "terraform_data" "base" {
  triggers_replace = local.is_nix ? local.image_path : null
}


resource "libvirt_volume" "root" {
  name     = "${var.name}.qcow2"
  pool     = var.pool
  capacity = var.spec.disk_size_bytes

  target = {
    format = {
      type = "qcow2"
    }
  }

  # Every root that has a base is a thin overlay on it, holding only what the
  # guest has written since it was created. A cloud lab's base is uploaded by
  # this module; a nix lab's is built and compressed by `just image` straight
  # into the pool directory, so that one is backed by path rather than by a
  # resource here. An iso lab has no base and gets an empty disk to install on.
  #
  # The overlay declares the registry's disk_size_bytes, which is larger than
  # the base it sits on — qcow2 reads past the end of a backing file as zeroes,
  # and the guest's growpart and x-systemd.growfs take the root filesystem out
  # to the full size on first boot. That is why the base is never resized.
  backing_store = (
    local.is_nix
    ? {
      path = local.image_path

      format = {
        type = "qcow2"
      }
    }
    : one([
      for v in libvirt_volume.base : {
        path = v.path

        format = {
          type = "qcow2"
        }
      }
    ])
  )

  lifecycle {
    replace_triggered_by = [terraform_data.base]
  }
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

  # Left to itself libvirt hands the guest one single-core socket per vCPU, and
  # QEMU invents a private 16 MiB L3 to go with each of them. The host is a
  # single-CCD 9800X3D where all eight cores sit under one 96 MiB V-Cache, so
  # that topology is not a simplification of the machine, it is the opposite of
  # it: the guest scheduler is told migrating a thread across cores costs
  # nothing, its cache-affinity logic is switched off by construction, and
  # anything that sizes itself from topology — rayon, OpenMP, jemalloc arenas,
  # make -j heuristics — reads a dozen machines where there is one. One socket
  # of `vcpu` cores puts the whole guest back under a single shared L3.
  #
  # The topology has to describe the hotplug ceiling rather than the boot count:
  # libvirt requires sockets * cores * threads to equal <vcpu>, and
  # vcpu_current only decides how many of those come online.
  #
  # threads stays 1 because nothing here pins a vCPU to a host thread. A guest
  # told that vCPU 0 and 1 are SMT siblings would keep work off one of them to
  # spare a shared pipeline the host is free to place anywhere — trading the
  # cache fiction for a scheduling one. Guest SMT is worth exposing the day
  # these labs pin, and not before.
  cpu = {
    mode = "host-passthrough"

    topology = {
      sockets = 1
      cores   = var.spec.vcpu
      threads = 1
    }

    # Without this QEMU invents the sizes to go with the topology it invented:
    # 64 KiB of 2-way L1d, 512 KiB of L2, and 16 MiB of L3 per socket. Cache
    # blocked code — BLAS, jemalloc, anything that reads getconf
    # LEVEL3_CACHE_SIZE — then sizes its tiles for 16 MiB and leaves five sixths
    # of the V-Cache unused, which on this host is the one number worth getting
    # right. Passthrough reports what the host actually has: 48 KiB 12-way L1d,
    # 1 MiB L2, 96 MiB L3.
    #
    # topoext has to be asked for by name. AMD publishes cache sizes in CPUID
    # leaf 0x8000001D, which is only readable when topoext is set, and QEMU
    # leaves it clear here even under host-passthrough — measured: passthrough
    # without it leaves the guest with no cache sysfs at all, which is worse
    # than the invented numbers it replaces.
    #
    # Passthrough is all or nothing — libvirt rejects a level-scoped one — so
    # the host's sharing counts come with its sizes, and the guest pairs its
    # cores into 8 L1/L2 groups it has no SMT to justify. That is naming, not a
    # lie: lstopo draws the host's own shape, the kernel builds no cluster
    # domain from it, and every count that decides how much work to start still
    # reports the vCPUs the guest can run on.
    cache = {
      mode = "passthrough"
    }

    features = [
      {
        name   = "topoext"
        policy = "require"
      }
    ]
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

        binary = {
          path = local.virtiofsd_path
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
      auto_deflate        = "off"

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
