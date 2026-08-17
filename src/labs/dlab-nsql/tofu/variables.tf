variable "libvirt_uri" {
  type = string
}

variable "storage_path" {
  type = string
}

variable "pool" {
  type = string
}

variable "network" {
  type = string
}

variable "subnet_prefix" {
  type = string
}

variable "username" {
  type = string
}

variable "ssh_authorized_keys" {
  type = list(string)
}
