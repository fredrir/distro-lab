provider "libvirt" {
  uri = "qemu:///system"
}

resource "libvirt_pool" "images" {
  name = "images"
  type = "dir"

  target = {
    path = "/storage/distro-lab/images"
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
