{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    cargo
    cargo-edit
    cargo-watch
    clippy
    mold
    rust-analyzer
    rustc
    rustfmt
    sccache
  ];

  environment.variables.RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
}
