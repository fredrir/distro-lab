variable "name" {
  type = string
}

variable "pool" {
  type    = string
  default = "images"
}

variable "network" {
  type    = string
  default = "default"
}

variable "iso_path" {
  type = string
}

variable "memory_mib" {
  type    = number
  default = 4096
}

variable "vcpus" {
  type    = number
  default = 4
}

variable "disk_size_bytes" {
  type    = number
  default = 53687091200
}

variable "boot_order" {
  type    = list(string)
  default = ["hd", "cdrom"]
}
