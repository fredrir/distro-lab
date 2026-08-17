{
  lib,
  pkgs,
  spec,
  ...
}:

let
  user = "fredrir";
  group = "fredrir";
  homeDir = "/home/${user}";
  mountUnit = "home-${user}.mount";

  # base.nix hands the login shell to zsh under the same condition, so the two
  # have to agree: a project lab gets zsh and everything below, a distro sandbox
  # is left with the stock bash so it looks like the distro it is testing.
  enabled = spec.kind == "project";

  # Same derivation as agents.nix: the lab's one checkout, or the home directory
  # itself for a project without a configured repository.
  repo = spec.repo or null;
  repoName =
    if repo == null then
      null
    else
      lib.removeSuffix ".git" (lib.last (lib.splitString "/" (toString repo)));
  projectDir = if repoName == null then homeDir else "${homeDir}/${repoName}";

  managedRc = "/etc/zsh/dlab/zshrc";
  userConfDir = "${homeDir}/.config/zsh/conf.d";
in
{
  config = lib.mkIf enabled {
    programs.zsh = {
      enable = true;

      # Starship draws the prompt, from a drop-in that ~/.zshrc reads after
      # /etc/zshrc.  Leaving promptinit enabled would build the default suse
      # prompt on every shell start for starship to immediately replace.
      promptInit = "";

      autosuggestions.enable = true;
      syntaxHighlighting.enable = true;

      # oh-my-zsh puts every enabled plugin's directory on fpath and then runs
      # compinit itself.  The global one in /etc/zshrc runs before any of that,
      # so it would dump a completion cache built from an fpath missing exactly
      # the plugins that came to add completions to it, and omz would rebuild it
      # a second time regardless.
      enableGlobalCompInit = false;
    };

    # Read-only, replaced as one closure by `just deploy <lab>`.  The home disk
    # holds no copy of it, so a lab cannot drift from what the flake says.
    environment.etc."zsh/dlab/zshrc".source = ../shell/zshrc;
    environment.etc."zsh/dlab/conf.d".source = ../shell/conf.d;

    environment.variables = {
      # The one per-lab fact the shell needs, and the only way a shipped static
      # file can know where this lab's checkout is.
      DLAB_PROJECT = projectDir;

      # Nothing clones ~/.oh-my-zsh on a lab: the framework is a store path from
      # the pin, so it updates with the flake and cannot drift. omz notices that
      # $ZSH is read-only and moves its own cache and completion dump to
      # ~/.cache/oh-my-zsh, which is on the persistent home disk.
      ZSH = "${pkgs.oh-my-zsh}/share/oh-my-zsh";

      # omz's fzf plugin owns the key bindings and fuzzy completion, which is
      # why programs.fzf stays off — it would source the same two files again.
      # The plugin hunts for an install prefix through a list of paths that a
      # store path is not on, so hand it the answer directly.
      FZF_BASE = "${pkgs.fzf}/share/fzf";
    };

    systemd.services.dlab-shell-home = {
      description = "Attach the lab shell configuration to ${homeDir}";

      wantedBy = [ "multi-user.target" ];
      after = [
        mountUnit
        "dlab-home-perms.service"
        # It creates ~/.config too, and only one of us should be the first to.
        "dlab-agent-home.service"
      ];
      requires = [
        mountUnit
        "dlab-home-perms.service"
      ];

      unitConfig.ConditionPathIsMountPoint = homeDir;

      path = [ pkgs.coreutils ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = user;
        Group = group;
      };

      script = ''
        rc=${homeDir}/.zshrc

        # Where a local tweak goes.  Created empty so it is discoverable, and on
        # the home disk so it survives a rebuild of the lab.
        install -d -m 0755 ${userConfDir}

        if [ -L "$rc" ] && [ "$(readlink "$rc")" = ${managedRc} ]; then
          exit 0
        fi

        # dlab-dotfiles is the case that matters: its own setup.sh plants a real
        # ~/.zshrc, and that checkout is the point of the lab.  Never move a file
        # aside to win an argument with it — say so and stand down.  /etc/zshrc
        # still applies either way.
        if [ -e "$rc" ] || [ -L "$rc" ]; then
          echo "keeping the ~/.zshrc already in place; the lab shell stays at ${managedRc}"
          exit 0
        fi

        ln -s ${managedRc} "$rc"
      '';
    };
  };
}
