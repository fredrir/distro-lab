{ ... }:

{
  boot.initrd.kernelModules = [ "virtiofs" ];

  fileSystems."/var/lib/dlab-state" = {
    device = "dlabstate";
    fsType = "virtiofs";

    options = [
      "nofail"
      "x-systemd.device-timeout=10s"
    ];
  };
}
