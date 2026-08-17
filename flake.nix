{
  description = "distro-lab dlab NixOS labs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      agenix,
      ...
    }@inputs:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};

      registry = builtins.fromJSON (builtins.readFile ./src/labs/labs.json);
      nixLabs = lib.filterAttrs (_: spec: spec.distro == "nixos") registry;

      # The same file the tofu registry module reads. A lab's address is settled
      # here at build time, which is why it is a tracked file and not a TF_VAR.
      network = builtins.fromJSON (builtins.readFile ./src/labs/network.json);

      secretsDir = builtins.path {
        path = ./src/labs/nixos/secrets;
        name = "dlab-secrets";
      };

      mkLab =
        name: spec:
        lib.nixosSystem {
          inherit system;

          specialArgs = {
            inherit
              inputs
              spec
              secretsDir
              network
              ;
            lab = name;
          };

          modules = [
            agenix.nixosModules.default
            ./src/labs/nixos/modules/base.nix
            ./src/labs/nixos/modules/net.nix
            ./src/labs/nixos/modules/core.nix
            ./src/labs/nixos/modules/shell.nix
            ./src/labs/nixos/modules/nvim.nix
            ./src/labs/nixos/modules/state.nix
            ./src/labs/nixos/modules/idle.nix
            ./src/labs/nixos/modules/secrets.nix
            ./src/labs/nixos/modules/agents.nix
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
