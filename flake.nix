{
  description = "distro-lab dlab NixOS labs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};

      registry = builtins.fromJSON (builtins.readFile ./src/labs/labs.json);
      nixLabs = lib.filterAttrs (_: spec: spec.distro == "nixos") registry;

      mkLab =
        name: spec:
        lib.nixosSystem {
          inherit system;

          specialArgs = {
            inherit inputs spec;
            lab = name;
          };

          modules = [
            ./src/labs/nixos/modules/base.nix
            ./src/labs/nixos/modules/core.nix
            ./src/labs/nixos/modules/state.nix
            ./src/labs/nixos/modules/idle.nix
            (./src/labs/nixos/hosts + "/${name}.nix")
          ];
        };
    in
    {
      nixosConfigurations = lib.mapAttrs mkLab nixLabs;

      images = lib.mapAttrs (_: cfg: cfg.config.system.build.image) self.nixosConfigurations;

      packages.${system} = lib.mapAttrs' (
        name: image: lib.nameValuePair "image-${name}" image
      ) self.images;

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          nixos-rebuild
          opentofu
          just
          jq
          age
          qemu-utils
        ];
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
