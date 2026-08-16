{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    opentofu
    terraform-ls
  ];
}
