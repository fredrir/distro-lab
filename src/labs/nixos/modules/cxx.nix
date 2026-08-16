{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    bear
    ccache
    clang-tools
    cmake
    cppcheck
    gdb
    meson
    ninja
    valgrind
  ];
}
