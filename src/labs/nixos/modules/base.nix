{
  config,
  lib,
  pkgs,
  modulesPath,
  lab,
  spec,
  ...
}:

{
  imports = [
    "${modulesPath}/virtualisation/disk-image.nix"
    "${modulesPath}/profiles/qemu-guest.nix"
  ];

  image.baseName = lab;
  image.format = "qcow2";
  image.efiSupport = true;

  boot.loader.systemd-boot.configurationLimit = 5;
  boot.loader.efi.canTouchEfiVariables = false;

  boot.kernelParams = [
    "console=ttyS0,115200"
    "console=tty0"
  ];

  networking.hostName = lab;
  networking.useDHCP = lib.mkDefault true;

  time.timeZone = "Europe/Oslo";

  services.openssh = {
    enable = true;
    openFirewall = true;

    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  services.qemuGuest.enable = true;

  services.udev.extraRules = ''
    SUBSYSTEM=="cpu", ACTION=="add", TEST=="online", ATTR{online}=="0", ATTR{online}="1"
  '';

  services.chrony = {
    enable = true;
    extraConfig = "makestep 1.0 -1";
  };

  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  users.groups.fredrir.gid = 1000;

  users.users.fredrir = {
    isNormalUser = true;
    uid = 1000;
    group = "fredrir";

    extraGroups = [ "wheel" ];

    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP7e69HsqnaggjeyngV0qUOurh5F9VMs7cudV0mu0QzD fhansteen@gmail.com"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH0jzc3S05J0DFj3W+Gv6J4Hc9fxvUjIOEuTWKfVnVY9 fhansteen@gmail.com"
    ];
  }
  // lib.optionalAttrs (spec.kind == "project") {
    shell = pkgs.zsh;
  };

  programs.zsh.enable = spec.kind == "project";

  security.sudo.wheelNeedsPassword = false;

  documentation.nixos.enable = false;

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];

    trusted-users = [
      "root"
      "fredrir"
    ];
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
    persistent = false;
    randomizedDelaySec = "45min";
  };

  nix.optimise.automatic = true;

  system.stateVersion = "26.05";
}
