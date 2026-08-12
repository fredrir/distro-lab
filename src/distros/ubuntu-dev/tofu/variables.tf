variable "libvirt_uri" {
  type = string
}

variable "pool" {
  type = string
}

variable "network" {
  type = string
}

variable "username" {
  type = string
}

variable "ssh_authorized_keys" {
  type = list(string)
}

variable "ubuntu_dev_memory_mib" {
  type = number
}

variable "ubuntu_dev_vcpus" {
  type = number
}

variable "ubuntu_dev_disk_size_bytes" {
  type = number
}

variable "ubuntu_dev_image_url" {
  type = string
}
