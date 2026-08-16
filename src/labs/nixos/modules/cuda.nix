{ config, pkgs, ... }:

let
  cuda = pkgs.cudaPackages_12_9;
in
{
  nixpkgs.config.allowUnfree = true;

  hardware.graphics.enable = true;

  hardware.nvidia = {
    package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
    open = false;
    modesetting.enable = false;
    nvidiaSettings = false;
    powerManagement.enable = false;
  };

  services.xserver.videoDrivers = [ "nvidia" ];

  boot.kernelPackages = pkgs.linuxPackages_6_12;

  programs.nix-ld.enable = true;

  environment.systemPackages = [
    cuda.cuda_nvcc
    cuda.cuda_cudart
    cuda.cuda_cupti
    cuda.cuda_gdb
    cuda.cuda_nvprof
    pkgs.gcc14
  ];

  environment.variables = {
    CUDA_PATH = "${cuda.cuda_nvcc}";
    CUDAHOSTCXX = "${pkgs.gcc14}/bin/g++";
  };
}
