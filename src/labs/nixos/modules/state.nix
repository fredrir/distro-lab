{ spec, ... }:

let
  hasSecrets = (spec.secrets or [ ]) != [ ];
in
{
  boot.initrd.kernelModules = [ "virtiofs" ];

  fileSystems."/var/lib/dlab-state" = {
    device = "dlabstate";
    fsType = "virtiofs";

    neededForBoot = hasSecrets;

    options =
      if hasSecrets then
        [ "defaults" ]
      else
        [
          "nofail"
          "x-systemd.device-timeout=10s"
        ];
  };
}
