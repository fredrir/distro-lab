{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    lua5_4
    lua54Packages.luacheck
    lua54Packages.luarocks
    luajit
    lua-language-server
    stylua
  ];
}
