{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    texliveMedium
    texlab
  ];
}
