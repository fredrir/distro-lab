{ pkgs, ... }:

let
  user = "fredrir";
  workDir = "/home/${user}/work";
  mountUnit = "home-${user}-work.mount";
in
{
  fileSystems.${workDir} = {
    device = "/dev/vdb";
    fsType = "ext4";

    options = [
      "nofail"
      "x-systemd.makefs"
      "x-systemd.device-timeout=30s"
    ];
  };

  systemd.services.dlab-work-perms = {
    description = "Hand the work disk to ${user} once it is mounted";

    wantedBy = [ "multi-user.target" ];
    after = [ mountUnit ];
    requires = [ mountUnit ];

    unitConfig.ConditionPathIsMountPoint = workDir;

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/chown ${user}:${user} ${workDir}";
    };
  };
}
