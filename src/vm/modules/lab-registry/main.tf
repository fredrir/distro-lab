locals {
  labs = {
    for name, lab in var.labs : name => {
      name   = name
      kind   = lab.kind
      distro = lab.distro
      title  = coalesce(lab.title, name)

      mac_address = join(":", [
        "52", "54", "00",
        substr(md5(name), 0, 2),
        substr(md5(name), 2, 2),
        substr(md5(name), 4, 2),
      ])

      ipv4 = "${var.subnet_prefix}.${lab.net.host}"

      source = {
        type       = lab.source.type
        host       = lab.source.host
        boot_order = lab.source.boot_order

        image_url = (
          lab.source.type == "nix"
          ? "file://${var.storage_path}/images/${name}-base.qcow2"
          : (
            can(regex("^[a-z0-9+.-]+://", lab.source.image))
            ? lab.source.image
            : "file://${var.storage_path}/${lab.source.image}"
          )
        )
      }

      memory_mib         = lab.memory_mib
      current_memory_mib = lab.current_memory_mib

      vcpu         = lab.vcpu
      vcpu_current = lab.vcpu_current
      cpu_shares   = lab.cpu_shares

      disk_size_bytes = lab.disk_size_bytes

      work_disk_bytes  = lab.work_disk_bytes
      work_volume_name = lab.work_disk_bytes > 0 ? "${name}-work.qcow2" : null

      state_share_path = "${var.storage_path}/storage/${name}/state"
      state_share_tag  = "dlabstate"

      gpu_pci = lab.gpu_pci
      idle    = lab.idle
      repo    = lab.repo
      secrets = lab.secrets
    }
  }
}
