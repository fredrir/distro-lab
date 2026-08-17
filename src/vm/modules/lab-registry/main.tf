locals {
  # Read rather than passed in: NixOS labs bake their own address into the image
  # at build time, and a flake cannot see the environment .env lives in. One
  # tracked file is the only way the image and the reservation cannot disagree.
  net = jsondecode(file("${path.module}/../../../labs/network.json"))

  network = {
    subnet_prefix = local.net.subnet_prefix
    prefix_length = local.net.prefix_length
    domain        = local.net.domain

    gateway_ipv4 = "${local.net.subnet_prefix}.${local.net.gateway_host}"
    netmask      = cidrnetmask("${local.net.subnet_prefix}.0/${local.net.prefix_length}")
  }

  # A nix lab's root is a thin overlay on its base, so the base is read-only for
  # as long as any root names it and can never be rewritten in place. `just
  # image` names each base after the store path it was built from and records
  # that path here; a new build lands beside the old one, this reads a different
  # backing path, and the root is recreated against it.
  #
  # Before the first `just image` there is nothing to read. Falling back to the
  # unstamped name keeps `just new-lab` — which applies the shared stack before
  # any image exists — working, and `just doctor` reports the real problem.
  nix_base = {
    for name, lab in var.labs : name => (
      fileexists("${var.storage_path}/images/${name}-base.store-path")
      ? "${var.storage_path}/images/${name}-base-${substr(
        basename(trimspace(file("${var.storage_path}/images/${name}-base.store-path"))), 0, 8
      )}.qcow2"
      : "${var.storage_path}/images/${name}-base.qcow2"
    )
    if lab.source.type == "nix"
  }

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

      ipv4 = "${local.net.subnet_prefix}.${lab.net.host}"

      source = {
        type       = lab.source.type
        host       = lab.source.host
        boot_order = lab.source.boot_order

        image_url = (
          lab.source.type == "nix"
          ? "file://${local.nix_base[name]}"
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
