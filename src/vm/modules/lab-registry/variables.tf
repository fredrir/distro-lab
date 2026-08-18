variable "labs" {
  type = map(object({
    kind   = string
    distro = string
    title  = optional(string)

    source = object({
      type       = string
      image      = optional(string)
      host       = optional(string)
      boot_order = optional(list(string), ["hd", "cdrom"])
    })

    net = object({
      host = number
    })

    memory_mib         = optional(number, 8192)
    current_memory_mib = optional(number, 4096)

    vcpu         = optional(number, 16)
    vcpu_current = optional(number, 4)
    cpu_shares   = optional(number, 1024)

    disk_size_bytes = optional(number, 68719476736)
    work_disk_bytes = optional(number, 0)

    gpu_pci = optional(list(string), [])

    idle = optional(object({
      minutes = optional(number, 60)
      action  = optional(string, "managedsave")
    }), {})

    repo    = optional(string)
    secrets = optional(list(string), [])

    agent = optional(object({
      skillsets = optional(list(string), [])
      skills    = optional(list(string), [])
    }), {})
  }))

  validation {
    condition     = alltrue([for k, v in var.labs : startswith(k, "dlab-")])
    error_message = "Lab names must start with dlab-."
  }

  validation {
    condition     = alltrue([for k, v in var.labs : contains(["distro", "project"], v.kind)])
    error_message = "kind must be one of distro, project."
  }

  validation {
    condition     = alltrue([for k, v in var.labs : contains(["cloud", "nix", "iso"], v.source.type)])
    error_message = "source.type must be one of cloud, nix, iso."
  }

  validation {
    condition     = alltrue([for k, v in var.labs : v.source.type == "nix" || v.source.image != null])
    error_message = "cloud and iso labs must set source.image."
  }

  validation {
    condition     = alltrue([for k, v in var.labs : v.source.type != "nix" || v.source.host != null])
    error_message = "nix labs must set source.host."
  }

  validation {
    condition     = alltrue([for k, v in var.labs : v.net.host > 1 && v.net.host < 255])
    error_message = "net.host must be between 2 and 254."
  }

  validation {
    condition     = length(distinct([for k, v in var.labs : v.net.host])) == length(var.labs)
    error_message = "net.host must be unique across labs."
  }

  validation {
    condition     = alltrue([for k, v in var.labs : v.memory_mib >= v.current_memory_mib])
    error_message = "memory_mib is the balloon ceiling and must be at least current_memory_mib."
  }

  validation {
    condition     = alltrue([for k, v in var.labs : v.vcpu >= v.vcpu_current])
    error_message = "vcpu is the hotplug ceiling and must be at least vcpu_current."
  }

  validation {
    condition     = alltrue([for k, v in var.labs : contains(["managedsave", "shutdown", "none"], v.idle.action)])
    error_message = "idle.action must be one of managedsave, shutdown, none."
  }

  validation {
    condition     = alltrue([for k, v in var.labs : length(v.gpu_pci) == 0 || v.idle.action != "managedsave"])
    error_message = "Labs with gpu_pci cannot use idle.action managedsave; libvirt refuses to serialise a domain with an assigned PCI device."
  }

  validation {
    condition     = alltrue([for k, v in var.labs : length(v.gpu_pci) == 0 || v.memory_mib == v.current_memory_mib])
    error_message = "Labs with gpu_pci must be sized statically; VFIO pins the whole guest footprint and QEMU inhibits the balloon."
  }

  # A save costs the ceiling, not the balloon. Guest RAM is memfd with shared
  # access — every lab carries a virtiofs share and that is the backing it
  # forces — and a read fault on a shared shmem mapping allocates. So when
  # managedsave walks the RAM block to write it out, it materialises the whole
  # of memory_mib on the host however little the guest is actually holding.
  #
  # Measured: dlab-nsql at 24576 with 1.2 GiB resident spent 29s climbing to
  # 17.4 GiB of shmem before the OOM killer took QEMU, which leaves the lab
  # hard-stopped with no save file — a power cut dressed as a suspend, and a
  # cold boot on the next connection. The same lab at 8192 saved in 2.9s and
  # restored in 1.9s.
  #
  # 12288 is what this host can materialise for one lab while another is awake:
  # 30 GiB, less the 4 GiB the lifecycle scripts reserve, less a second lab's
  # resident set. Raise it only alongside host memory, and never above what
  # `just doctor` reports as available.
  validation {
    condition     = alltrue([for k, v in var.labs : v.idle.action != "managedsave" || v.memory_mib <= 12288])
    error_message = "Labs using idle.action managedsave must keep memory_mib at or below 12288; a save materialises the ceiling and a larger one OOM-kills the domain it is saving."
  }

  validation {
    condition     = alltrue([for k, v in var.labs : v.repo == null || v.work_disk_bytes > 0])
    error_message = "Labs with a repo need work_disk_bytes for the checkout to survive a rebuild."
  }
}

variable "storage_path" {
  type = string
}
