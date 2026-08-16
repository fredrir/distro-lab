let
  registry = builtins.fromJSON (builtins.readFile ../../labs.json);

  users = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP7e69HsqnaggjeyngV0qUOurh5F9VMs7cudV0mu0QzD"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH0jzc3S05J0DFj3W+Gv6J4Hc9fxvUjIOEuTWKfVnVY9"
  ];

  labKey =
    lab:
    builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile (./hosts + "/${lab}.pub"));

  forLab =
    lab: spec:
    builtins.listToAttrs (
      map (name: {
        name = "${lab}/${name}.age";
        value.publicKeys = users ++ [ (labKey lab) ];
      }) (spec.secrets or [ ])
    );

  perLab = builtins.attrValues (builtins.mapAttrs forLab registry);
in
builtins.foldl' (acc: entry: acc // entry) { } perLab
