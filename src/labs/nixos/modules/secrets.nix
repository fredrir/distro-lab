{
  lib,
  spec,
  lab,
  secretsDir,
  ...
}:

let
  secrets = spec.secrets or [ ];
in
{
  config = lib.mkIf (secrets != [ ]) {
    age.identityPaths = lib.mkForce [ "/var/lib/dlab-state/agenix.key" ];

    age.secrets = lib.genAttrs secrets (name: {
      file = secretsDir + "/${lab}/${name}.age";
      owner = "fredrir";
      group = "fredrir";
      mode = "0400";
    });
  };
}
