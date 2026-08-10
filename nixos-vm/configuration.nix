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
"ssh-ed25519 AAAA...ARCH_KEY..."
"ssh-ed25519 AAAA...MACBOOK_KEY..."
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
