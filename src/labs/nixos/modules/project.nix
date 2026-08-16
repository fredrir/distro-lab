{
  lib,
  pkgs,
  spec,
  ...
}:

let
  user = "fredrir";
  repo = spec.repo or null;

  name = lib.removeSuffix ".git" (lib.last (lib.splitString "/" (toString repo)));

  workDir = "/home/${user}/work";
  dest = "${workDir}/${name}";
  keyPath = "/run/agenix/deploy-key";
  mountUnit = "home-${user}-work.mount";
in
{
  config = lib.mkIf (repo != null) {
    programs.ssh.knownHosts.github = {
      hostNames = [ "github.com" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
    };

    programs.ssh.extraConfig = ''
      Host github.com
        User git
        IdentityFile ${keyPath}
        IdentitiesOnly yes
    '';

    programs.git.config = {
      user.name = "fredrir";
      user.email = "fhansteen@gmail.com";
      safe.directory = dest;
    };

    systemd.services.dlab-project = {
      description = "Check out ${name} into ${workDir}";

      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        mountUnit
        "dlab-work-perms.service"
      ];
      requires = [
        mountUnit
        "dlab-work-perms.service"
      ];

      unitConfig.ConditionPathIsMountPoint = workDir;

      path = [
        pkgs.git
        pkgs.openssh
      ];

      environment = {
        HOME = "/home/${user}";
        GIT_TERMINAL_PROMPT = "0";
        GIT_SSH_COMMAND = "ssh -o BatchMode=yes -o IdentitiesOnly=yes -i ${keyPath}";
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = user;
        Group = user;
        TimeoutStartSec = "600";
      };

      script = ''
        if [ -e ${dest}/.git ]; then
            if git -C ${dest} rev-parse --verify HEAD >/dev/null 2>&1; then
                git -C ${dest} remote set-url origin ${repo}
                exit 0
            fi
            broken=${dest}.broken.$(date +%Y%m%dT%H%M%S)
            echo "checkout at ${dest} has no usable HEAD, moving it to $broken" >&2
            mv ${dest} "$broken"
        fi

        staging=$(mktemp -d ${workDir}/.dlab-clone.XXXXXX)
        trap 'rm -rf "$staging"' EXIT

        git clone ${repo} "$staging/${name}"
        mv "$staging/${name}" ${dest}
      '';
    };
  };
}
