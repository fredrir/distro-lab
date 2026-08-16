{ ... }:

{
  fileSystems."/home/fredrir/work" = {
    device = "/dev/vdb";
    fsType = "ext4";

    options = [
      "nofail"
      "x-systemd.makefs"
      "x-systemd.device-timeout=30s"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /home/fredrir/work 0755 fredrir fredrir -"
  ];
}
