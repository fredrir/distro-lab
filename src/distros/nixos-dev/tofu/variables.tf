variable "libvirt_uri" {
  type = string
}

variable "distro_lab_path" {
  type = string
}

variable "pool" {
  type = string
}

variable "network" {
  type = string
}

variable "nixos_dev_memory_mib" {
  type = number
}

variable "nixos_dev_vcpus" {
  type = number
}

variable "nixos_dev_disk_size_bytes" {
  type = number
}

variable "nixos_dev_iso" {
  type = string
}

variable "nixos_dev_boot_order" {
  type = list(string)
}
