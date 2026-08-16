{ ... }:

{
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    dockerSocket.enable = true;
  };

  users.users.fredrir.extraGroups = [ "podman" ];
}
