provider "libvirt" {
  uri = var.libvirt_uri
}

resource "libvirt_pool" "images" {
  name = var.pool
  type = "dir"

  target = {
    path = "${var.distro_lab_path}/images"
  }

  create = {
    build     = false
    start     = true
    autostart = true
  }

  destroy = {
    delete = false
  }
}
