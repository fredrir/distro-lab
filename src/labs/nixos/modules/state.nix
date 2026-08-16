{ spec, ... }:

let
  hasSecrets = (spec.secrets or [ ]) != [ ];
  needsState = hasSecrets || spec.kind == "project";
in
{
  boot.initrd.kernelModules = [ "virtiofs" ];

  fileSystems."/var/lib/dlab-state" = {
    device = "dlabstate";
    fsType = "virtiofs";

    neededForBoot = needsState;

    options =
      if needsState then
        [ "defaults" ]
      else
        [
          "nofail"
          "x-systemd.device-timeout=10s"
        ];
  };
}
