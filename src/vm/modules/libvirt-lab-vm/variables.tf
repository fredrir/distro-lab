variable "name" {
  type = string
}

variable "spec" {
  type = object({
    title       = string
    mac_address = string

    source = object({
      type       = string
      image_url  = string
      boot_order = list(string)
    })

    memory_mib         = number
    current_memory_mib = number

    vcpu         = number
    vcpu_current = number
    cpu_shares   = number

    disk_size_bytes  = number
    work_volume_name = string

    state_share_path = string
    state_share_tag  = string

    gpu_pci = list(string)
  })
}

variable "pool" {
  type    = string
  default = "images"
}

variable "network" {
  type    = string
  default = "dlab"
}

variable "username" {
  type    = string
  default = "fredrir"
}

variable "ssh_authorized_keys" {
  type = list(string)
}

variable "cloud_config_extra" {
  type    = any
  default = {}
}

variable "virtiofsd_path" {
  type    = string
  default = null
}

variable "running" {
  type    = bool
  default = false
}

variable "autostart" {
  type    = bool
  default = false
}
