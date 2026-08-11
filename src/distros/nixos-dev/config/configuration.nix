{ config, pkgs, ... }:

{
imports = [
./hardware-configuration.nix
];

boot.loader.systemd-boot.enable = true;
boot.loader.efi.canTouchEfiVariables = true;

networking.hostName = "nixos-dev";

services.openssh = {
enable = true;
openFirewall = true;

settings = {
PasswordAuthentication = false;
PermitRootLogin = "no";
};
};

services.qemuGuest.enable = true;

users.users.fredrir = {
isNormalUser = true;

extraGroups = [
"wheel"
];

openssh.authorizedKeys.keys = [
"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP7e69HsqnaggjeyngV0qUOurh5F9VMs7cudV0mu0QzD archie"
"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH0jzc3S05J0DFj3W+Gv6J4Hc9fxvUjIOEuTWKfVnVY9 macie"
];
};

security.sudo.wheelNeedsPassword = false;

environment.systemPackages = with pkgs; [
git
vim
curl
];

system.stateVersion = "26.05";
}
